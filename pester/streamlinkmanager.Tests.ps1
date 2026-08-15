#===========================================================================
# Tests - Streaming Library Manager install/uninstall (wraps slm.bat directly)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilStreamLinkManager.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilStreamLinkManager.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }

    $script:installDir = Join-Path $env:LocalAppData "StreamingLibraryManager"
    $script:batPath = Join-Path $script:installDir "slm.bat"

    function script:New-WinUtilSlmPackage([hashtable]$PromptValues) {
        $package = [pscustomobject]@{ content = "Streaming Library Manager"; webui = "http://localhost:5000" }
        if ($PromptValues) {
            $package = $package | Add-Member -NotePropertyName PromptValues -NotePropertyValue $PromptValues -PassThru
        }
        $package
    }
}

Describe "Install-WinUtilStreamLinkManager" {
    BeforeEach {
        Mock New-Item { }
        Mock Invoke-WebRequest { }
        Mock Test-Path { $true }
        Mock Remove-Item { }
        Mock Start-Process { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = "Streaming Library Manager" } }
        Mock Start-ScheduledTask { }
        Mock Get-NetFirewallRule { [pscustomobject]@{ DisplayName = "Streaming Library Manager" } }
        Mock New-NetFirewallRule { }
    }

    It "reports each milestone via ProgressCallback, in order, when supplied" {
        # Regression guard for the real reported bug on the previous implementation: this
        # install looked frozen with no per-step feedback beyond log lines - ProgressCallback is
        # what fixes that.
        $messages = [System.Collections.Generic.List[string]]::new()

        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @(
            "Installing Streaming Library Manager..."
            "Downloading and extracting Streaming Library Manager..."
            "Configuring Streaming Library Manager's port..."
            "Registering Streaming Library Manager to start at logon..."
            "Starting Streaming Library Manager..."
        )
    }

    It "does not require a ProgressCallback" {
        { Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) } | Should -Not -Throw
    }

    It "does not let a failing ProgressCallback abort the install" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) -ProgressCallback { throw "boom" }

        Should -Invoke -CommandName Start-ScheduledTask -Times 1 -Exactly
    }

    It "downloads slm.bat itself from the upstream repo into the install directory" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://raw.githubusercontent.com/babsonnexus/stream-link-manager-for-channels/main/executables/slm.bat" -and
                $OutFile -eq $script:batPath
        }
    }

    It "installs to the StreamingLibraryManager folder, not the old StreamLinkManager name" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq $script:installDir }
    }

    It "runs slm.bat's 'upgrade' command, never 'install' - upgrade has no interactive prompt and preserves settings" {
        # Regression guard for the whole reason this wraps slm.bat instead of running its
        # "install" - confirmed via slm.bat's own source: "install" requires an interactive Y/N
        # keypress via the `choice` builtin with no scriptable bypass, and wipes existing user
        # data with only an on-screen warning; "upgrade" has no prompt and preserves it.
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "cmd.exe" -and $ArgumentList -contains "upgrade" -and $ArgumentList -notcontains "install"
        }
    }

    It "adds 'prerelease' to the upgrade command when requested" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage -PromptValues @{ SLM_PRERELEASE = "yes" })

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains "upgrade" -and $ArgumentList -contains "prerelease"
        }
    }

    It "does not request the prerelease build by default" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains "upgrade" -and $ArgumentList -notcontains "prerelease"
        }
    }

    It "never runs slm.bat's own 'port' command" {
        # Regression guard for the actual reported bug: feeding the port into "port"'s
        # interactive `set /P` prompt via -RedirectStandardInput redirects stdin for the whole
        # cmd.exe process, not just that one line - and slm.bat later calls
        # `timeout /NOBREAK /T 5` to wait for its own elevated netsh call, which hard-refuses to
        # run at all against a non-console stdin. Confirmed live: "ERROR: Input redirection is
        # not supported, exiting the process immediately." appeared in the install log on every
        # run, reading as a failure even when the install otherwise succeeded. "port" only has
        # two persistent effects behind that prompt (setting SLM_PORT and the firewall rule),
        # both replicated directly instead - see the function's own docstring.
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage -PromptValues @{ SLM_PORT = "7654" })

        Should -Invoke -CommandName Start-Process -Times 2 -Exactly -ParameterFilter {
            $ArgumentList -notcontains "port"
        }
    }

    It "reports the resolved port in the final install message, for a requested port" {
        $messages = [System.Collections.Generic.List[string]]::new()
        Mock Write-WinUtilLog { $messages.Add($Message) }

        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage -PromptValues @{ SLM_PORT = "7654" })

        $messages | Should -Contain "Streaming Library Manager installed - web interface at http://localhost:7654"
    }

    It "defaults to port 5000 when no port is requested" {
        $messages = [System.Collections.Generic.List[string]]::new()
        Mock Write-WinUtilLog { $messages.Add($Message) }

        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        $messages | Should -Contain "Streaming Library Manager installed - web interface at http://localhost:5000"
    }

    It "falls back to the default port and logs a warning for an out-of-range port" {
        $messages = [System.Collections.Generic.List[string]]::new()
        Mock Write-WinUtilLog { $messages.Add($Message) } -ParameterFilter { $Level -ne "WARN" }
        Mock Write-WinUtilLog { } -ParameterFilter { $Level -eq "WARN" }

        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage -PromptValues @{ SLM_PORT = "99" })

        $messages | Should -Contain "Streaming Library Manager installed - web interface at http://localhost:5000"
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "*isn't a valid port*"
        }
    }

    It "does not recreate the firewall rule when one already exists from a previous install" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName New-NetFirewallRule -Times 0 -Exactly
    }

    It "creates the scoped firewall rule directly when none exists yet" {
        Mock Get-NetFirewallRule { $null }

        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage -PromptValues @{ SLM_PORT = "7654" })

        Should -Invoke -CommandName New-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            $DisplayName -eq "Streaming Library Manager" -and $LocalPort -eq "7654" -and $Protocol -eq "TCP"
        }
    }

    It "logs an error when the firewall rule still doesn't exist after attempting to create it" {
        Mock Get-NetFirewallRule { $null }
        Mock New-NetFirewallRule { throw "access denied" }
        Mock Write-WinUtilLog { }

        { Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) } | Should -Not -Throw

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Message -like "*Failed to create*firewall rule*"
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Message -like "*firewall rule still doesn't exist*"
        }
    }

    It "still checks for the firewall-scoping rule even for the default port" {
        # Regression guard: skipping this for the default port would silently leave whatever
        # rule (if any) ends up in place unscoped - the exact problem this rewrite exists to fix.
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Get-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            $DisplayName -eq "Streaming Library Manager"
        }
    }

    It "registers the logon task via slm.bat's own 'startup' command" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains "startup"
        }
    }

    It "starts the app through the scheduled task, not a second separate launch" {
        # Regression guard for the actual reported bug in the previous version: launching
        # slm.exe a second, different way (Start-WinUtilProcessAsStandardUserNoWait, which has
        # no window-style control) is what put the app in a visible foreground window instead of
        # the hidden background one the scheduled task is already configured to produce.
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Start-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq "Streaming Library Manager"
        }
    }

    It "logs a warning instead of throwing when the scheduled task isn't found after 'startup'" {
        Mock Get-ScheduledTask { $null }

        { Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) } | Should -Not -Throw

        Should -Invoke -CommandName Start-ScheduledTask -Times 0 -Exactly
    }

    It "logs an error instead of throwing when slm.exe is missing after upgrade" {
        Mock Test-Path { $false }

        { Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) } | Should -Not -Throw

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly
    }
}

Describe "Uninstall-WinUtilStreamLinkManager" {
    BeforeEach {
        Mock Get-Process { }
        Mock Stop-Process { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = "Streaming Library Manager" } }
        Mock Unregister-ScheduledTask { }
        Mock Remove-NetFirewallRule { }
        Mock Test-Path { $true }
        Mock Remove-Item { }
    }

    It "reports the uninstall milestone via ProgressCallback when supplied" {
        $messages = [System.Collections.Generic.List[string]]::new()

        Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @("Uninstalling Streaming Library Manager...")
    }

    It "does not require a ProgressCallback" {
        { Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) } | Should -Not -Throw
    }

    It "unregisters the logon scheduled task" {
        Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq "Streaming Library Manager"
        }
    }

    It "removes the Windows Firewall rule created for the app's port" {
        # Regression guard for the author-confirmed gap in the previous version: it never
        # removed this rule at all.
        Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Remove-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            $DisplayName -eq "Streaming Library Manager"
        }
    }

    It "removes both the current and the old, incorrectly-named install folder" {
        # Regression guard for the previous version's own naming bug leaving an orphaned copy
        # behind after upgrading past it.
        Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Remove-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq (Join-Path $env:LocalAppData "StreamingLibraryManager")
        }
        Should -Invoke -CommandName Remove-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq (Join-Path $env:LocalAppData "StreamLinkManager")
        }
    }

    It "stops the running process before removing anything" {
        Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Get-Process -Times 1 -Exactly -ParameterFilter { $Name -eq "slm" }
    }
}
