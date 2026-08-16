Function Install-WinUtilStreamLinkManager {
    <#
    .SYNOPSIS
        Installs Streaming Library Manager by downloading and running the upstream slm.bat
        launcher directly, rather than reimplementing its install/upgrade/port/startup steps.

    .DESCRIPTION
        An earlier version of this function reimplemented slm.bat's download-and-extract steps
        natively, specifically to avoid its interactive Y/N "install" prompt. Author-confirmed
        (babsonnexus, reviewing that approach): reimplementing it created a real, growing feature
        gap instead of avoiding a small one. Concretely, that version: had no port selection (and
        so never set SLM_PORT, and so never created the properly-scoped Windows Firewall rule
        slm.bat's own "port" command creates - whatever ended up allowing traffic through was a
        broad, unscoped, per-app rule instead), named the install folder "StreamLinkManager"
        instead of "StreamingLibraryManager", had no way to choose the prerelease build, and -
        confirmed as an actual bug, not just a missing feature - launched the app in a visible
        foreground window instead of hidden/background, because
        Start-WinUtilProcessAsStandardUserNoWait has no window-style control at all. This version
        wraps slm.bat itself, so all of that tracks upstream directly instead of drifting.

        Uses "upgrade", never "install" - confirmed via slm.bat's own source
        (.../executables/slm.bat): "install" shows an interactive Y/N confirmation via the
        `choice` builtin with no scriptable bypass, while "upgrade" has no prompt at all and,
        per the author's own testing of this rewrite, correctly preserves the existing
        installation's program files across a reinstall - "install" does not; it wipes them,
        with only an on-screen warning. On a completely fresh install "upgrade" behaves
        identically to "install" anyway (there is nothing yet to preserve), so there is no
        reason to ever use "install" here.

        slm.bat is downloaded fresh into the install directory on every run, not bundled or
        cached - it is a small, frequently-updated launcher script, and downloading it fresh
        means this always runs upstream's current install/upgrade/port/startup logic exactly,
        with nothing here to fall out of sync as that script changes. Immediately after
        downloading it, Optimize-WinUtilSlmBat patches its own download/extract/wait commands in
        place for speed and to work correctly under a redirected stdin - see that function's own
        docstring for exactly what and why. That patch is applied once, before any of the three
        invocations below, since all three run the same downloaded file.

        Routed through cmd.exe explicitly (Start-Process -FilePath cmd.exe -ArgumentList "/c",
        $batPath, ...), not Start-Process -FilePath $batPath directly - the same reasoning as
        Install-WinUtilProgramNpm's npm.cmd handling: -NoNewWindow forces UseShellExecute to
        $false, which does a literal CreateProcess-style launch with no .bat file-association
        resolution, so slm.bat has to be handed to cmd.exe explicitly rather than relying on
        Windows to figure out how to run it.

        Port selection (catalog "prompts": SLM_PORT, an optional text field - blank keeps the
        default 5000) is fed into slm.bat's own "port" command via -RedirectStandardInput from a
        small temp file, answering its interactive `set /P` prompt non-interactively. Confirmed
        live this used to have a real side effect: redirecting stdin lasts for the cmd.exe
        process's whole lifetime, not just that one line, and slm.bat later calls
        `timeout /NOBREAK /T 5` to wait for the elevated netsh call it just kicked off (via its
        own -Verb RunAs) to finish - timeout.exe hard-refuses to run at all against a non-console
        stdin, printing a real, user-visible error and exiting instantly instead of actually
        waiting, while slm.bat still prints "has been opened" unconditionally regardless of what
        actually happened. Fixed at the source by Optimize-WinUtilSlmBat, which replaces every
        `timeout /NOBREAK /T 5` in the downloaded file with a wait that doesn't care about stdin
        at all - not by avoiding "port" or reimplementing what it does. Calling "port" itself,
        rather than replicating its two persistent effects (setx SLM_PORT and the netsh firewall
        rule) directly, keeps this on the same footing as "upgrade" and "startup": tracking
        upstream's own current logic for that command, not a second copy of it that could drift.

        The existing firewall rule (if any) is removed unconditionally before "port" runs, not
        just when it's found to be stale - author-confirmed gap: netsh (what slm.bat's own
        "port" command uses to create it) doesn't enforce unique rule names, so changing SLM_PORT
        on an upgrade used to leave the old port's rule behind as a second, orphaned rule with
        the same DisplayName rather than replacing it. Removing first, every run, guarantees at
        most one rule for this app exists afterward regardless of whether the port actually
        changed.

        The firewall rule is still verified afterward, not just trusted from slm.bat's own
        output - if it's still missing (the timeout.exe race is fixed, but nothing guarantees an
        elevated, UAC-gated background process finishes in any particular window), this creates
        it directly as a fallback, and that fallback's own result is checked too, not fired and
        forgotten, since a silently swallowed failure there would leave the port unreachable with
        nothing in the log to explain why.

        "startup" registers slm.bat's own scheduled task, which - per its own source - always
        runs at RunLevel highest (elevated), self-elevating via -Verb RunAs just to register it.
        Left as-is here rather than overridden to run de-elevated, which is what the previous
        version of this function did. That is a deliberate divergence from how WinUtil de-elevates
        its own installer launches elsewhere: the whole point of wrapping slm.bat directly is to
        defer to its own author's choices instead of second-guessing them from outside. Both
        "port" and "startup" may trigger their own UAC prompts as a result (slm.bat's own -Verb
        RunAs calls, not something this function controls) - expected, not a bug to route around.

        The initial "start now" launch runs slm.bat itself with no handle, not
        Start-ScheduledTask - author-confirmed gap in the previous version: the just-registered
        task showed as "Queued" in Task Scheduler rather than actually running, needing a manual
        "Run" click to start it. Start-ScheduledTask, triggered from WinUtil's own elevated
        process, doesn't reliably resolve the interactive-session token an "onlogon" /
        RunLevel-highest task expects, apparently a known rough edge for that combination rather
        than something specific to this task. slm.bat's own no-handle default (`if exist
        "%executable%" (call %run_command%)`) already does exactly the launch this needed -
        `Start-Process -WindowStyle hidden` on slm.exe - which was in fact the author's own
        suggested alternative to the previous version's separate, visibly-foreground
        Start-WinUtilProcessAsStandardUserNoWait launch ("execute the Task Scheduler item... or
        do what the .bat does"). Using slm.bat's own default here sidesteps the Task Scheduler
        rough edge entirely for the immediate launch, while "startup" above still leaves the real
        scheduled task registered correctly for every future login, which is a completely
        different code path (the OS itself triggers it at actual logon, not
        Start-ScheduledTask) and isn't affected by this.

        This one call - unlike the three before it - is run without -Wait. Confirmed live: with
        it, the whole install hung indefinitely (5+ minutes and still going) right after logging
        "Starting Streaming Library Manager", with nothing further and no error. -NoNewWindow
        shares handles down the entire process tree it spawns (cmd.exe -> the nested powershell
        -> Start-Process -WindowStyle hidden slm.exe), and slm.exe is the one target across all
        four invocations that's actually meant to keep running afterward, not exit - a classic
        .NET Process.WaitForExit gotcha: waiting doesn't stop at the immediate child, it stops
        once every process still holding an inherited handle exits, and a persistent web server
        never does. "upgrade"/"port"/"startup" never hit this because everything they spawn is
        short-lived and exits on its own. Nothing here depends on this particular call finishing
        anyway - the actual launch (slm.bat's own hidden Start-Process, already fired by the time
        this returns) is what matters, not the wrapper cmd.exe process around it.

        $env:SLM_PORT is set here, directly, right before this specific launch - author-confirmed
        bug: SLM started on the catalog's default port 5000 instead of the one just configured,
        during the very install/upgrade run that set it. slm.bat's own "port" command sets
        SLM_PORT via setx, which only writes the registry for processes started AFTER that write
        - it never touches the environment block of a process already running, and every launch
        in this function is a descendant of WinUtil's own single, already-running process, so
        none of them see it through inheritance no matter how long after "port" they run. A
        genuinely new session (an actual logon, which is exactly what makes the scheduled task
        above correct for every future login - never the problem here) rebuilds its environment
        from the registry fresh and would see it correctly; upstream's own script says as much
        ("restart Streaming Library Manager in a new window for the port to take effect"), which
        is effectively what the author suggested (launch a separate terminal just for this).
        Setting $env:SLM_PORT here instead is simpler and doesn't require detaching a real new
        session: this process already holds the correct value in $port, and environment
        variables inherit down the whole spawn chain from whoever sets them - cmd.exe, then the
        nested powershell.exe it runs, then finally slm.exe itself - so correcting it once, at
        the top of that chain, right before it's spawned, reaches every link below it.

        The catalog's "webui" field (the popup's "Open" button target) is resolved dynamically
        via Resolve-WinUtilAppWebUI rather than used as a fixed string, since SLM_PORT can differ
        from the catalog's declared default - see that function's own docstring.

        ProgressCallback works the same way as Install-WinUtilProgramDirect's - see that
        function's docstring for why it exists.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    $batUrl = "https://raw.githubusercontent.com/babsonnexus/stream-link-manager-for-channels/main/executables/slm.bat"
    $taskName = "Streaming Library Manager"
    $firewallRuleName = "Streaming Library Manager"

    # Invoke-WebRequest's default live progress-bar rendering redraws on every buffer chunk and
    # can slow a large download by 10-100x (well-documented PowerShell behavior, worst on
    # Windows PowerShell 5.1). Function-local, so it reverts automatically for the caller once
    # this function returns.
    $ProgressPreference = 'SilentlyContinue'

    foreach ($package in $Packages) {
        $name = $package.content
        $installDir = Join-Path $env:LocalAppData "StreamingLibraryManager"
        $batPath = Join-Path $installDir "slm.bat"

        $port = "5000"
        if ($package.PromptValues -and -not [string]::IsNullOrWhiteSpace($package.PromptValues["SLM_PORT"])) {
            $requested = $package.PromptValues["SLM_PORT"].Trim()
            if ($requested -match '^\d+$' -and [int]$requested -ge 1000 -and [int]$requested -le 9999) {
                $port = $requested
            } else {
                Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: '$requested' isn't a valid port (1000-9999) - using the default 5000."
            }
        }

        $prerelease = $package.PromptValues -and ($package.PromptValues["SLM_PRERELEASE"] -imatch '^y(es)?$')

        Write-WinUtilLog -Component "Package" -Message "Installing $name to $installDir"
        if ($ProgressCallback) { try { & $ProgressCallback "Installing $name..." } catch {} }

        $portInputFile = $null
        try {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null

            Write-WinUtilLog -Component "Package" -Message "Downloading slm.bat"
            Invoke-WebRequest -Uri $batUrl -OutFile $batPath -UseBasicParsing -TimeoutSec 60
            Optimize-WinUtilSlmBat -Path $batPath | Out-Null

            $upgradeArgs = @("/c", $batPath, "upgrade")
            if ($prerelease) { $upgradeArgs += "prerelease" }
            Write-WinUtilLog -Component "Package" -Message "Running slm.bat $($upgradeArgs[2..($upgradeArgs.Count - 1)] -join ' ')"
            if ($ProgressCallback) { try { & $ProgressCallback "Downloading and extracting $name..." } catch {} }
            Start-Process -FilePath "cmd.exe" -ArgumentList $upgradeArgs -NoNewWindow -Wait

            $exePath = Join-Path $installDir "slm.exe"
            if (-not (Test-Path $exePath)) {
                throw "slm.exe not found after running slm.bat upgrade - the upstream release layout may have changed."
            }

            Write-WinUtilLog -Component "Package" -Message "Setting $name's port to $port"
            if ($ProgressCallback) { try { & $ProgressCallback "Configuring $name's port..." } catch {} }
            # Removed unconditionally, not just when it's stale, so this always starts from a
            # clean slate - netsh (what slm.bat's own "port" command uses) doesn't enforce unique
            # rule names, so re-running "port" with a different value each upgrade would otherwise
            # accumulate a second rule for the old port rather than replacing it, exactly the
            # author-reported gap.
            Remove-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue
            $portInputFile = Join-Path $env:TEMP "slm-port-input-$([guid]::NewGuid().ToString('N')).txt"
            Set-Content -Path $portInputFile -Value $port -Encoding ASCII
            Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $batPath, "port") -NoNewWindow -Wait -RedirectStandardInput $portInputFile

            if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
                try {
                    New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -ErrorAction Stop | Out-Null
                } catch {
                    Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to create $name's firewall rule for port ${port}: $_"
                }
                if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
                    Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$name's firewall rule still doesn't exist after attempting to create it - port $port may not be reachable until one is added manually."
                }
            }

            Write-WinUtilLog -Component "Package" -Message "Registering $name to start at logon"
            if ($ProgressCallback) { try { & $ProgressCallback "Registering $name to start at logon..." } catch {} }
            Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $batPath, "startup") -NoNewWindow -Wait

            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Write-WinUtilLog -Component "Package" -Message "Starting $name"
                if ($ProgressCallback) { try { & $ProgressCallback "Starting $name..." } catch {} }
                # slm.bat's own "port" command sets SLM_PORT via setx, which only writes the
                # registry for future processes - it never touches the environment block of a
                # process already running, this one included. Setting it here, directly in our
                # own process right before spawning this launch, is what actually makes the
                # value reach slm.exe: env vars inherit down the whole spawn chain (cmd.exe -> a
                # nested powershell.exe -> Start-Process -WindowStyle hidden on slm.exe), so
                # correcting it at the top of that chain fixes every link below it too, with no
                # dependency on setx's registry round-trip (which only a genuinely new session -
                # an actual logon - re-reads; that's also why the scheduled task above works
                # correctly for every future login and was never the problem here).
                $env:SLM_PORT = $port
                Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $batPath) -NoNewWindow
            } else {
                Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name's scheduled task wasn't found after 'slm.bat startup' - start it manually from $installDir."
            }

            Write-WinUtilLog -Component "Package" -Message "$name installed - web interface at http://localhost:$port"
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to install ${name}: $_"
        } finally {
            if ($portInputFile) { Remove-Item $portInputFile -Force -ErrorAction SilentlyContinue }
        }
    }
}
