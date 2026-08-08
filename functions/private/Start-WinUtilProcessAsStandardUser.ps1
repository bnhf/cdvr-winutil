function Start-WinUtilProcessAsStandardUser {
    <#
    .SYNOPSIS
        Launches a process at the user's normal (non-elevated) integrity level from within
        WinUtil's elevated process - for operations like winget that behave incorrectly (or
        refuse outright) when run as Administrator against per-user-scope packages.

    .DESCRIPTION
        Uses the Shell.Application COM "ShellExecute" de-elevation trick: asks the already-
        running, non-elevated explorer.exe shell process to launch the target on our behalf,
        rather than trying to mint a de-elevated process ourselves via token APIs.

        An earlier version of this helper used CreateProcessWithTokenW with the UAC "linked"
        standard-user token, which looked correct on paper (SeImpersonatePrivilege enabled,
        valid linked token) but reliably failed with ERROR_ACCESS_DENIED (Win32 error 5) when
        called from an ordinary elevated process. That's a real, widely-documented limitation
        of CreateProcessWithTokenW: it's implemented via the Secondary Logon service, which
        applies extra checks effectively restricting it to LocalSystem-level callers, not
        regular elevated Administrator tokens. The Shell.Application route sidesteps that
        entirely, since Explorer - not us - creates the child process.

        Because ShellExecute is fire-and-forget (no process handle/PID is returned), the
        actual target is launched indirectly via a small generated wrapper .ps1 that runs it
        with Start-Process -Wait, then writes the resulting exit code to a sentinel file. This
        helper polls for that file so callers still get a reliable exit code, the same way
        they would from Start-Process -PassThru -Wait.

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

    try {
        $workingDir = Split-Path -Path $FilePath -Parent
        if ([string]::IsNullOrWhiteSpace($workingDir)) { $workingDir = $env:TEMP }

        $token = [guid]::NewGuid().ToString("N")
        $wrapperScript = Join-Path $env:TEMP "cdvr-deelevate-$token.ps1"
        $sentinelFile = Join-Path $env:TEMP "cdvr-deelevate-$token.txt"

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

        $shell = New-Object -ComObject "Shell.Application"
        $shellArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapperScript`""
        $shell.ShellExecute("powershell.exe", $shellArgs, $workingDir, "open", 0)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

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
        foreach ($f in @($wrapperScript, $sentinelFile)) {
            if ($f -and (Test-Path $f)) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
        }
    }
}
