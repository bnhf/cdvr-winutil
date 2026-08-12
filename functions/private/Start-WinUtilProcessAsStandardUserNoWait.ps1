function Start-WinUtilProcessAsStandardUserNoWait {
    <#
    .SYNOPSIS
        Launches a process at the user's normal (non-elevated) integrity level from within
        WinUtil's elevated process, without waiting for it to exit - for installers that launch
        a long-running application on completion (e.g. Channels DVR Server's installer starts
        the DVR engine itself when the wizard finishes, which never exits on its own).

    .DESCRIPTION
        A separate function from Start-WinUtilProcessAsStandardUser, not a -NoWait switch on it -
        that function's de-elevation works by running the target through a generated wrapper
        script that does Start-Process -Wait, then polls for a sentinel file the wrapper writes
        with the exit code. For a target that never exits, that wrapper's own -Wait would hang
        forever too, and that function's "de-elevation failed, run elevated instead" fallback
        would incorrectly trigger on the resulting timeout - launching the installer a second
        time, elevated, on top of the still-running de-elevated one. A never-exiting target isn't
        a failure here, so it can't share that function's contract.

        Uses the same Scheduled Task + RunLevel "Limited" technique (see that function's own
        docstring for why this approach and not CreateProcessWithTokenW/Shell.Application COM,
        both of which proved unreliable), but the task's action launches the target directly -
        no wrapper script, no sentinel file, no waiting, since there is no exit code to report
        back and callers here don't need one.

        The task registration is removed shortly after starting, not left around - this only
        unregisters the task definition, not the process it already spawned, the same way
        deleting a shortcut doesn't close a program already launched from it.

    .OUTPUTS
        $true if the task was registered and started (the target was launched, though its own
        success/failure afterward is unknown - the same as calling Start-Process and not waiting).
        $false if de-elevation itself could not be set up, in which case the caller should fall
        back to launching the process normally (elevated).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @()
    )

    $taskName = $null

    try {
        $workingDir = Split-Path -Path $FilePath -Parent
        if ([string]::IsNullOrWhiteSpace($workingDir)) { $workingDir = $env:TEMP }

        $taskName = "CDVR-WinUtil-Deelevate-NoWait-$([guid]::NewGuid().ToString('N'))"

        Import-Module ScheduledTasks -ErrorAction Stop

        $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $argumentString = $ArgumentList -join ' '
        $actionParams = @{ Execute = $FilePath; WorkingDirectory = $workingDir }
        if (-not [string]::IsNullOrWhiteSpace($argumentString)) { $actionParams.Argument = $argumentString }
        $action = New-ScheduledTaskAction @actionParams
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel
        $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings

        Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        # Give Task Scheduler a moment to actually spawn the process before unregistering the
        # task definition - unregistering doesn't touch the already-spawned process, but doing
        # it before Start-ScheduledTask has taken effect could plausibly race with the launch.
        Start-Sleep -Seconds 2

        return $true
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Could not launch $FilePath as standard user, running elevated instead: $_"
        return $false
    } finally {
        if ($taskName -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
