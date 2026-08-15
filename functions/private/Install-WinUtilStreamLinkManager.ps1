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
        with nothing here to fall out of sync as that script changes.

        Routed through cmd.exe explicitly (Start-Process -FilePath cmd.exe -ArgumentList "/c",
        $batPath, ...), not Start-Process -FilePath $batPath directly - the same reasoning as
        Install-WinUtilProgramNpm's npm.cmd handling: -NoNewWindow forces UseShellExecute to
        $false, which does a literal CreateProcess-style launch with no .bat file-association
        resolution, so slm.bat has to be handed to cmd.exe explicitly rather than relying on
        Windows to figure out how to run it.

        Port selection (catalog "prompts": SLM_PORT, an optional text field - blank keeps the
        default 5000) is fed into slm.bat's own "port" command via -RedirectStandardInput from a
        small temp file, not a piped string - `set /P` reading from a redirected input FILE is a
        standard, reliable way to script an interactive prompt like this; feeding it through
        PowerShell's own pipeline into an external process has known quirks Start-Process's
        stdin redirection avoids entirely. Run unconditionally, even for the default port 5000,
        because "port" is also the ONLY thing that creates the properly-scoped Windows Firewall
        rule (scoped to exactly that TCP port) - skipping it for the default port would silently
        reproduce the too-broad-firewall problem this rewrite exists to fix.

        Confirmed live: -RedirectStandardInput has a side effect slm.bat's own "port" handler
        doesn't expect - it redirects stdin for the cmd.exe process's whole lifetime, not just
        the one `set /P` line it's meant for, and slm.bat later calls `timeout /NOBREAK /T 5` to
        wait for the elevated netsh call it just kicked off (via its own -Verb RunAs) to finish.
        timeout.exe hard-refuses to run at all against a non-console stdin ("Input redirection is
        not supported, exiting the process immediately") and exits instantly instead of actually
        waiting, so slm.bat can end up deleting its temp netsh script before that elevated,
        UAC-gated process has necessarily had a chance to read it - a real race, not just a log
        warning, that slm.bat's own code never checks the result of (it prints "has been opened"
        unconditionally either way). Confirmed live this didn't matter when WinUtil's own already-
        elevated process meant -Verb RunAs completed near-instantly with nothing to wait on - but
        that's timing, not a guarantee, so the actual firewall rule is verified independently
        below rather than trusted from slm.bat's own output, with this function creating it
        itself as a fallback if slm.bat's attempt didn't land.

        "startup" registers slm.bat's own scheduled task, which - per its own source - always
        runs at RunLevel highest (elevated), self-elevating via -Verb RunAs just to register it.
        Left as-is here rather than overridden to run de-elevated, which is what the previous
        version of this function did. That is a deliberate divergence from how WinUtil de-elevates
        its own installer launches elsewhere: the whole point of wrapping slm.bat directly is to
        defer to its own author's choices instead of second-guessing them from outside. Both
        "port" and "startup" may trigger their own UAC prompts as a result (slm.bat's own -Verb
        RunAs calls, not something this function controls) - expected, not a bug to route around.

        The initial "start now" launch runs through that same scheduled task
        (Start-ScheduledTask), not a second, separate launch of slm.exe - per the author's
        feedback on the previous version, its separate launch path
        (Start-WinUtilProcessAsStandardUserNoWait, which has no window-style control at all) is
        exactly what put the app in a visible foreground window instead of the hidden background
        one the scheduled task is already configured to produce.

        Known limitation: the catalog's "webui" field (the popup's "Open" button target) is a
        fixed "http://localhost:5000" - it does not update if SLM_PORT is set to something else
        here. Nothing currently threads an install-time value back into that static field.

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
            $portInputFile = Join-Path $env:TEMP "slm-port-input-$([guid]::NewGuid().ToString('N')).txt"
            Set-Content -Path $portInputFile -Value $port -Encoding ASCII
            Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $batPath, "port") -NoNewWindow -Wait -RedirectStandardInput $portInputFile

            if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
                Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name's firewall rule wasn't found after 'slm.bat port' - creating it directly instead."
                New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -ErrorAction SilentlyContinue | Out-Null
            }

            Write-WinUtilLog -Component "Package" -Message "Registering $name to start at logon"
            if ($ProgressCallback) { try { & $ProgressCallback "Registering $name to start at logon..." } catch {} }
            Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $batPath, "startup") -NoNewWindow -Wait

            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Write-WinUtilLog -Component "Package" -Message "Starting $name"
                if ($ProgressCallback) { try { & $ProgressCallback "Starting $name..." } catch {} }
                Start-ScheduledTask -TaskName $taskName
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
