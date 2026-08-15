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
        Mock Set-Content { }
        Mock Remove-Item { }
        Mock Start-Process { }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = "Streaming Library Manager" } }
        Mock Start-ScheduledTask { }
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

    It "runs slm.bat's 'port' command with the requested port piped in via redirected stdin" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage -PromptValues @{ SLM_PORT = "7654" })

        Should -Invoke -CommandName Set-Content -Times 1 -Exactly -ParameterFilter { $Value -eq "7654" }
        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains "port" -and $RedirectStandardInput
        }
    }

    It "defaults to port 5000 when no port is requested" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Set-Content -Times 1 -Exactly -ParameterFilter { $Value -eq "5000" }
    }

    It "falls back to the default port and logs a warning for an out-of-range port" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage -PromptValues @{ SLM_PORT = "99" })

        Should -Invoke -CommandName Set-Content -Times 1 -Exactly -ParameterFilter { $Value -eq "5000" }
    }

    It "still creates the firewall-scoping 'port' rule even for the default port" {
        # Regression guard: "port" is the only thing that creates the properly-scoped Windows
        # Firewall rule - skipping it for the default port would silently leave whatever traffic
        # rule ends up in place unscoped, the exact problem this rewrite exists to fix.
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains "port"
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

    It "removes the Windows Firewall rule slm.bat's own 'port' command created" {
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
