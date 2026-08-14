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

        Also makes a best-effort attempt to bring the launched window to the foreground.
        Confirmed live: de-elevated installer windows launched this way don't reliably get
        Windows' automatic foreground grant (that's tied to whichever thread most recently
        received user input, not this background runspace), so they could open without the user
        noticing. There's no process handle to hand to Set-WinUtilProcessForeground the normal
        way - Start-ScheduledTask doesn't return one - so this looks for a process at the exact
        path just launched that started within the last few seconds instead. Best-effort only:
        wrapped separately from the de-elevation contract above, since a failure here (window
        never found, access denied reading another process's properties, ...) must never make
        this function report $false - the caller would then treat de-elevation ITSELF as having
        failed and launch the installer a second time, elevated, on top of the one that actually
        did start correctly. Won't find the right window for installers that self-extract and
        re-exec as a different process (a real limitation, not attempted here) - a miss just
        means no foreground happens, same as before this existed.

        Also calls AllowSetForegroundWindow(ASFW_ANY) right before starting the task - added
        after Open-WinUtilLink was switched to call this function with FilePath set to
        explorer.exe (routing web UI/GUI links through it, not just installer continuations).
        Confirmed live: everything launched that way opened behind WinUtil's own window. The
        process-path-match logic above can't fix that for this caller - explorer.exe invoked
        with an argument either hands off to the already-running shell and exits almost
        immediately (nothing left to match by the time the 2-second sleep above elapses), or,
        just as often, the target is a browser that's already running and simply opens a new
        tab in its existing window - no new process at all, so there's no "just launched"
        process to find by path regardless of timing. AllowSetForegroundWindow(ASFW_ANY) sidesteps
        needing to know the target process's identity or window handle at all: called by
        WinUtil while it still owns the foreground, it grants ANY process permission to
        successfully call SetForegroundWindow once, system-wide, until the next input event -
        letting whichever process actually ends up handling the request (a brand-new instance,
        or an existing one just surfacing a new tab) foreground itself via its own normal
        activation code. This is the standard Windows-documented mechanism for exactly this
        "I'm about to trigger something that will show a window shortly after, on a process I
        don't control" scenario. Best-effort like the block above - failure here is swallowed
        and never turns into a reported de-elevation failure either.

        The process-path-match search itself is skipped entirely when FilePath is explorer.exe
        (the link-relay case) rather than merely finding nothing. Confirmed live this was the
        actual cause of WinUtil appearing to lock up after opening a link: explorer.exe invoked
        with an argument is a transient relay with no window of its own, so on the (fairly
        common) occasions it hadn't exited yet by the time the search ran, it matched, and
        Set-WinUtilProcessForeground then polled for up to its own 15-second timeout waiting for
        a MainWindowHandle that this relay process was never going to have - blocking on it for
        nothing every time that race landed the wrong way, since AllowSetForegroundWindow above
        already does everything this case needs.

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

        try {
            if (-not ([System.Management.Automation.PSTypeName]'WinUtil.ForegroundPermissionNative').Type) {
                Add-Type -Namespace WinUtil -Name ForegroundPermissionNative -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
'@ -ErrorAction Stop
            }
            [void][WinUtil.ForegroundPermissionNative]::AllowSetForegroundWindow(-1)  # ASFW_ANY
        } catch {}

        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        # Give Task Scheduler a moment to actually spawn the process before unregistering the
        # task definition - unregistering doesn't touch the already-spawned process, but doing
        # it before Start-ScheduledTask has taken effect could plausibly race with the launch.
        Start-Sleep -Seconds 2

        try {
            if ($FilePath -ine "$env:WINDIR\explorer.exe") {
                $launchedProcess = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                    $samePath = $false
                    try { $samePath = $_.Path -eq $FilePath } catch {}
                    $samePath -and $_.StartTime -gt (Get-Date).AddSeconds(-10)
                } | Sort-Object StartTime -Descending | Select-Object -First 1

                if ($launchedProcess) {
                    Set-WinUtilProcessForeground -Process $launchedProcess
                }
            }
        } catch {}

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
