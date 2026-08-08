function Start-WinUtilProcessAsStandardUser {
    <#
    .SYNOPSIS
        Launches a process at the user's normal (non-elevated) integrity level from within
        WinUtil's elevated process - for operations like winget that behave incorrectly (or
        refuse outright) when run as Administrator against per-user-scope packages.

    .DESCRIPTION
        Uses a temporary Scheduled Task with RunLevel "Limited" (TASK_RUNLEVEL_LUA) to launch
        the target. That RunLevel is the OS-documented mechanism for forcing a task to run
        with the user's standard, filtered token even when the principal is an administrator
        and the caller registering the task is elevated - Task Scheduler itself performs the
        de-elevation, so there's no dependency on token APIs or COM behaving a particular way.

        Two earlier approaches were tried and both proved unreliable in practice:
        - CreateProcessWithTokenW with the UAC "linked" standard-user token looked correct on
          paper (SeImpersonatePrivilege enabled, valid linked token) but reliably failed with
          ERROR_ACCESS_DENIED (Win32 error 5) when called from an ordinary elevated process.
          That API is implemented via the Secondary Logon service, which applies extra checks
          effectively restricting it to LocalSystem-level callers, not elevated Administrator
          tokens.
        - Shell.Application COM's ShellExecute (the commonly-referenced "ask Explorer to
          launch it" trick) silently did not de-elevate: New-Object -ComObject
          "Shell.Application" from an elevated process instantiates the COM object in-process
          rather than marshaling out to the existing non-elevated explorer.exe, so the launched
          process just inherited our elevated token anyway.

        Because Start-ScheduledTask is fire-and-forget (no process handle/PID is returned),
        the actual target is launched indirectly via a small generated wrapper .ps1 that runs
        it with Start-Process -Wait, then writes the resulting exit code to a sentinel file.
        This helper polls for that file so callers still get a reliable exit code, the same
        way they would from Start-Process -PassThru -Wait.

        Falls back to running the process normally (at the current, elevated, integrity) if
        any step fails or times out - this is a best-effort correctness improvement, not
        something that should ever hard-fail an install/uninstall.

    .OUTPUTS
        A [pscustomobject] with an .ExitCode property, so callers can read it the same way
        they would with Start-Process -PassThru -Wait.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 300
    )

    $wrapperScript = $null
    $sentinelFile = $null
    $taskName = $null

    try {
        $workingDir = Split-Path -Path $FilePath -Parent
        if ([string]::IsNullOrWhiteSpace($workingDir)) { $workingDir = $env:TEMP }

        $token = [guid]::NewGuid().ToString("N")
        $wrapperScript = Join-Path $env:TEMP "cdvr-deelevate-$token.ps1"
        $sentinelFile = Join-Path $env:TEMP "cdvr-deelevate-$token.txt"
        $taskName = "CDVR-WinUtil-Deelevate-$token"

        $argArrayLiteral = "@(" + (($ArgumentList | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ")"
        $filePathLiteral = "'" + ($FilePath -replace "'", "''") + "'"
        $sentinelLiteral = "'" + ($sentinelFile -replace "'", "''") + "'"

        $wrapperContent = @"
try {
    `$p = Start-Process -FilePath $filePathLiteral -ArgumentList $argArrayLiteral -NoNewWindow -Wait -PassThru
    `$p.ExitCode | Out-File -FilePath $sentinelLiteral -Encoding ascii
} catch {
    "ERROR: `$_" | Out-File -FilePath $sentinelLiteral -Encoding ascii
}
"@
        Set-Content -Path $wrapperScript -Value $wrapperContent -Encoding UTF8

        Import-Module ScheduledTasks -ErrorAction Stop

        $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $shellArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapperScript`""
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $shellArgs -WorkingDirectory $workingDir
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel
        $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings

        Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-Path $sentinelFile) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
        }

        if (-not (Test-Path $sentinelFile)) {
            throw "Timed out after ${TimeoutSeconds}s waiting for de-elevated process to complete."
        }

        $result = (Get-Content -Path $sentinelFile -Raw).Trim()
        if ($result -like "ERROR:*") {
            throw "De-elevated process wrapper failed: $result"
        }

        $exitCode = [int]$result
        return [pscustomobject]@{ ExitCode = $exitCode }
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Could not run $FilePath as standard user, running elevated instead: $_"
        return Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru
    } finally {
        if ($taskName -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        foreach ($f in @($wrapperScript, $sentinelFile)) {
            if ($f -and (Test-Path $f)) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
        }
    }
}
