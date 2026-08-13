Function Install-WinUtilProgramNpm {
    <#
    .SYNOPSIS
        Installs or uninstalls a global npm package. Requires Node.js/npm to already be on
        PATH - packages using this installType should declare "nodejs" in their "requires".

    .DESCRIPTION
        ProgressCallback works the same way as Install-WinUtilProgramDirect's - see that
        function's docstring for why it exists.

        Runs npm via "cmd.exe /c", not Start-Process -FilePath "npm" directly - confirmed live,
        the direct form fails with "%1 is not a valid Win32 application." The Node.js Windows
        installer's own "npm" is npm.cmd, a batch shim, not a real .exe; -NoNewWindow forces
        Start-Process's underlying ProcessStartInfo.UseShellExecute to $false, which performs a
        literal CreateProcess-style launch with no file-association resolution, so it tries to
        execute the batch file's raw bytes as a native binary instead of dispatching it through
        cmd.exe the way typing "npm ..." at a prompt would. This exact error was previously
        masked by an earlier PATH-detection bug (npm wasn't found on PATH at all, so this call
        was never reached) - fixing that surfaced this next, previously-unreachable failure.

        npmAllowScripts (catalog field, optional) passes "--allow-scripts=<value>" through to
        npm - npm blocks a dependency's own install/postinstall scripts by default unless
        explicitly allowlisted (confirmed live for Prismcast: ffmpeg-for-homebridge's
        install.js, which fetches its bundled ffmpeg binary, was silently skipped, only logged
        as an npm warning rather than failing the install outright). Deliberately per-package,
        not a blanket "allow everything" flag for every npm-type install - that would defeat the
        point of npm's own default-deny protection against arbitrary install-time code execution
        for every OTHER npm-type package, most of which have no declared need for it.

        preUninstallCommand (catalog field, optional) runs before "npm uninstall", the mirror of
        postInstallCommand running after "npm install" - added for Prismcast specifically, whose
        "prismcast service install" postInstallCommand registers a Task Scheduler-based
        background service that keeps a node.exe process running. A package's own declared
        shutdown command is a best-effort courtesy, not the actual guarantee that unblocks npm -
        see the CIM-based kill below for that.

        Every Uninstall also directly finds and force-stops any node.exe process still running
        THIS package's own files, independent of - and after - preUninstallCommand, rather than
        trusting a package's own shutdown mechanism to have actually released them. Confirmed
        live for Prismcast across three rounds: "prismcast service uninstall" alone didn't stop
        it; reading Prismcast's own source showed why ("service uninstall" only deregisters the
        scheduled task, it never calls "service stop", the one that actually runs
        Stop-ScheduledTask) and its declared preUninstallCommand was fixed to call "service stop"
        directly - but npm's own uninstall still failed with EBUSY afterward regardless, meaning
        even Stop-ScheduledTask terminating the Task Scheduler-launched PowerShell launcher
        process doesn't reliably cascade to the node.exe it spawned as its own child via
        Start-Process (a real, if opaque, gap in how Windows Job Object termination propagates
        through nested Start-Process launches - not something any amount of extra waiting fixes,
        since the process was never actually dying in the first place). Matched by command line,
        not by image name ("node.exe" alone would kill every unrelated Node process on the
        system) - requiring both "node_modules" and the exact package name to appear together is
        specific enough that only a process actually running THIS package's own entry point
        matches. This is deliberately unconditional (not gated on preUninstallCommand being
        declared), since any npm-type package that keeps a background process running - now or
        in the future - can hit the exact same EBUSY problem, not just Prismcast.
    #>
    param (
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install",

        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    # Node.js (npm's own prerequisite) may have installed via winget/choco earlier in this same
    # run - refresh PATH so this process actually sees it instead of reporting a false negative.
    Update-WinUtilSessionPath

    foreach ($package in $Packages) {
        $name = $package.content
        $npmPackage = $package.npmPackage

        if ([string]::IsNullOrWhiteSpace($npmPackage)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm $($Action.ToLower()) for $name is missing npmPackage."
            continue
        }

        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm is not on PATH - can't $($Action.ToLower()) $name."
            continue
        }

        if ($Action -eq "Uninstall") {
            if (-not [string]::IsNullOrWhiteSpace($package.preUninstallCommand)) {
                Write-WinUtilLog -Component "Package" -Message "Running pre-uninstall step for $name`: $($package.preUninstallCommand)"
                try {
                    & ([scriptblock]::Create($package.preUninstallCommand))
                    Write-WinUtilLog -Component "Package" -Message "$name pre-uninstall step completed"
                } catch {
                    Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Pre-uninstall step failed for ${name}: $_"
                }
            }

            try {
                $lockingProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like "*node_modules*$npmPackage*" })
                foreach ($lockingProcess in $lockingProcesses) {
                    Write-WinUtilLog -Component "Package" -Message "Stopping node.exe (PID $($lockingProcess.ProcessId)) still running $name before uninstall"
                    Stop-Process -Id $lockingProcess.ProcessId -Force -ErrorAction SilentlyContinue
                }
                if ($lockingProcesses.Count -gt 0) {
                    Start-Sleep -Milliseconds 500
                }
            } catch {}
        }

        $npmVerb = if ($Action -eq "Uninstall") { "uninstall" } else { "install" }
        $npmArgs = @("/c", "npm", $npmVerb, "-g", $npmPackage)
        if ($Action -eq "Install" -and -not [string]::IsNullOrWhiteSpace($package.npmAllowScripts)) {
            $npmArgs += "--allow-scripts=$($package.npmAllowScripts)"
        }

        Write-WinUtilLog -Component "Package" -Message "$Action $name via npm ($npmPackage)"
        if ($ProgressCallback) { try { & $ProgressCallback "$Action $name via npm..." } catch {} }
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList $npmArgs -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$name npm $($npmVerb) completed (exit code: $($process.ExitCode))"

        # Some npm-distributed tools need a separate step to actually start running (or set up
        # their own auto-start) after the package itself is installed - e.g. Prismcast installs
        # as a dormant CLI until "prismcast service install" registers and starts it as a
        # background service.
        if ($Action -eq "Install" -and $process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($package.postInstallCommand)) {
            Write-WinUtilLog -Component "Package" -Message "Running post-install step for $name`: $($package.postInstallCommand)"
            try {
                & ([scriptblock]::Create($package.postInstallCommand))
                Write-WinUtilLog -Component "Package" -Message "$name post-install step completed"
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Post-install step failed for ${name}: $_"
            }
        }
    }
}
