#===========================================================================
# Tests - GitHub-install-type uninstall via the registered Windows uninstaller
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilProgramUninstallString.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilProgramGithub.ps1")
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPortableGithubInstallDir.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilPortableGithubInstalled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Stop-WinUtilProcessByAssetPattern.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }
    function Set-WinUtilProcessForeground { param($Process) }
    function Start-WinUtilProcessAsStandardUserNoWait { param($FilePath, $ArgumentList) }
}

Describe "Get-WinUtilPortableGithubInstallDir" {
    It "builds a fixed, namespaced folder under LocalAppData from the package name" {
        Get-WinUtilPortableGithubInstallDir -Name "Pluto for Channels" |
            Should -Be (Join-Path $env:LocalAppData "CDVRWinUtil-Portable\Pluto for Channels")
    }
}

Describe "Test-WinUtilPortableGithubInstalled" {
    It "returns false when the install folder doesn't exist" {
        Mock Test-Path { $false }

        Test-WinUtilPortableGithubInstalled -Name "Pluto for Channels" -AssetPattern "PlutoForChannels*.exe" | Should -BeFalse
    }

    It "returns true when a file matching the asset pattern exists in the install folder" {
        Mock Test-Path { $true }
        Mock Get-ChildItem { [pscustomobject]@{ Name = "PlutoForChannels.exe" } }

        Test-WinUtilPortableGithubInstalled -Name "Pluto for Channels" -AssetPattern "PlutoForChannels*.exe" | Should -BeTrue

        Should -Invoke -CommandName Get-ChildItem -Times 1 -Exactly -ParameterFilter {
            $Filter -eq "PlutoForChannels*.exe"
        }
    }

    It "returns false when the install folder exists but contains no matching file" {
        Mock Test-Path { $true }
        Mock Get-ChildItem { $null }

        Test-WinUtilPortableGithubInstalled -Name "Pluto for Channels" -AssetPattern "PlutoForChannels*.exe" | Should -BeFalse
    }
}

Describe "Stop-WinUtilProcessByAssetPattern" {
    BeforeEach {
        function taskkill { param([Parameter(ValueFromRemainingArguments = $true)]$Arguments) }
        Mock taskkill { }
    }

    It "strips everything after the first wildcard, keeping the wildcard, before building the filter" {
        # Regression guard for the actual root cause behind three separate live reports of the
        # same symptom (Pluto for Channels' uninstall reporting incomplete, and a reinstall
        # failing to replace a locked file): confirmed empirically against a real running
        # process, taskkill's /FI IMAGENAME filter only supports a wildcard with NOTHING after
        # it - "IMAGENAME eq cm*" correctly matched and killed a real process; "IMAGENAME eq
        # cm*.exe" failed outright with "ERROR: The search filter cannot be recognized." An
        # earlier fix used "taskkill /IM PlutoForChannels*.exe" directly, which was ALSO
        # confirmed empirically to silently match and kill nothing at all - /IM doesn't support
        # wildcards despite being commonly described as if it did.
        Stop-WinUtilProcessByAssetPattern -AssetPattern "PlutoForChannels*.exe"

        Should -Invoke -CommandName taskkill -Times 1 -Exactly -ParameterFilter {
            (@($Arguments) -join "|") -eq '/F|/FI|IMAGENAME eq PlutoForChannels*|/T'
        }
    }

    It "passes a literal pattern through unchanged when it has no wildcard at all" {
        Stop-WinUtilProcessByAssetPattern -AssetPattern "slm.exe"

        Should -Invoke -CommandName taskkill -Times 1 -Exactly -ParameterFilter {
            (@($Arguments) -join "|") -eq '/F|/FI|IMAGENAME eq slm.exe|/T'
        }
    }
}

Describe "Get-WinUtilProgramUninstallString" {
    BeforeEach {
        Mock Get-ItemProperty { @() }
    }

    It "returns the UninstallString for exactly one match" {
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = "Clicker"; UninstallString = '"C:\Program Files\Clicker\unins000.exe"' }
            )
        }

        $result = Get-WinUtilProgramUninstallString -DisplayNamePattern "*Clicker*"

        $result.UninstallString | Should -Be '"C:\Program Files\Clicker\unins000.exe"'
        $result.Reason | Should -BeNullOrEmpty
    }

    It "returns null with a clear reason when nothing matches" {
        $result = Get-WinUtilProgramUninstallString -DisplayNamePattern "*Clicker*"

        $result.UninstallString | Should -BeNullOrEmpty
        $result.Reason | Should -Match "No program matching"
    }

    It "refuses to guess when more than one entry matches, rather than risk the wrong uninstaller" {
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = "Clicker"; UninstallString = "C:\A\unins000.exe" }
                [pscustomobject]@{ DisplayName = "Clicker Beta"; UninstallString = "C:\B\unins000.exe" }
            )
        }

        $result = Get-WinUtilProgramUninstallString -DisplayNamePattern "*Clicker*"

        $result.UninstallString | Should -BeNullOrEmpty
        $result.Reason | Should -Match "Found 2 programs"
    }

    It "ignores registry entries with no UninstallString" {
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = "Clicker"; UninstallString = $null }
            )
        }

        $result = Get-WinUtilProgramUninstallString -DisplayNamePattern "*Clicker*"

        $result.UninstallString | Should -BeNullOrEmpty
    }

    It "returns null with a reason rather than throwing when the registry query itself fails" {
        Mock Get-ItemProperty { throw "access denied" }

        { Get-WinUtilProgramUninstallString -DisplayNamePattern "*Clicker*" } | Should -Not -Throw
        (Get-WinUtilProgramUninstallString -DisplayNamePattern "*Clicker*").Reason | Should -Match "Failed to query"
    }
}

Describe "Uninstall-WinUtilProgramGithub" {
    BeforeEach {
        Mock Set-WinUtilProcessForeground { }
        Mock Start-WinUtilProcessAsStandardUserNoWait { $true }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-WinUtilProgramUninstallString {
            [pscustomobject]@{ UninstallString = '"C:\Program Files\Clicker\unins000.exe"'; Reason = $null }
        }
    }

    It "looks up the package by its content field and runs the registered uninstaller via cmd /c" {
        $package = [pscustomobject]@{ content = "Clicker" }

        Uninstall-WinUtilProgramGithub -Packages @($package)

        Should -Invoke -CommandName Get-WinUtilProgramUninstallString -Times 1 -Exactly -ParameterFilter {
            $DisplayNamePattern -eq "*Clicker*"
        }
        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "cmd.exe" -and (@($ArgumentList) -join "|") -eq '/c|"C:\Program Files\Clicker\unins000.exe"'
        }
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "falls back to an elevated launch (with foreground) when de-elevation fails" {
        Mock Start-WinUtilProcessAsStandardUserNoWait { $false }

        Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Clicker" })

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq "cmd.exe" }
        Should -Invoke -CommandName Set-WinUtilProcessForeground -Times 1 -Exactly
    }

    It "does not attempt to launch anything when no matching uninstaller is found" {
        Mock Get-WinUtilProgramUninstallString {
            [pscustomobject]@{ UninstallString = $null; Reason = "No program matching '*Clicker*' found in Windows' Add/Remove Programs list." }
        }

        Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Clicker" })

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 0 -Exactly
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "reports the lookup and uninstall milestones via ProgressCallback" {
        $messages = [System.Collections.Generic.List[string]]::new()

        Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Clicker" }) -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @("Looking up Clicker...", "Uninstalling Clicker...")
    }

    Context "portable packages (no setup wizard, never register in Add/Remove Programs)" {
        BeforeEach {
            Mock Write-WinUtilLog { }
            Mock Stop-WinUtilProcessByAssetPattern { }
            Mock Start-Sleep { }
            Mock Test-Path { $true }
            Mock Remove-Item { }
        }

        It "stops any running instance via Stop-WinUtilProcessByAssetPattern and deletes the fixed install folder, without an Add/Remove Programs lookup" {
            # Regression guard for the actual reported bug: Pluto for Channels' uninstall always
            # failed with "No program matching '*Pluto for Channels*' found in Windows'
            # Add/Remove Programs list" - confirmed via its own repo docs, this app is a
            # standalone portable exe that never registers itself there, so that lookup could
            # never succeed no matter what was actually installed. Stopping the running instance
            # itself took three rounds to get right - see Stop-WinUtilProcessByAssetPattern's own
            # docstring for that history.
            $installDir = Get-WinUtilPortableGithubInstallDir -Name "Pluto for Channels"
            $package = [pscustomobject]@{ content = "Pluto for Channels"; portable = $true; assetPattern = "PlutoForChannels*.exe" }

            Uninstall-WinUtilProgramGithub -Packages @($package)

            Should -Invoke -CommandName Stop-WinUtilProcessByAssetPattern -Times 1 -Exactly -ParameterFilter {
                $AssetPattern -eq "PlutoForChannels*.exe"
            }
            Should -Invoke -CommandName Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq $installDir -and $Recurse -eq $true -and $Force -eq $true
            }
            Should -Invoke -CommandName Get-WinUtilProgramUninstallString -Times 0 -Exactly
        }

        It "does not call Stop-WinUtilProcessByAssetPattern when the package has no assetPattern to match by" {
            Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Pluto for Channels"; portable = $true })

            Should -Invoke -CommandName Stop-WinUtilProcessByAssetPattern -Times 0 -Exactly
        }

        It "does not attempt to delete anything when the install folder doesn't exist" {
            Mock Test-Path { $false }

            Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Pluto for Channels"; portable = $true })

            Should -Invoke -CommandName Remove-Item -Times 0 -Exactly
        }

        It "logs a clear success message once the install folder is confirmed gone after deletion" {
            $installDir = Get-WinUtilPortableGithubInstallDir -Name "Pluto for Channels"
            $script:testPathCallCount = 0
            Mock Test-Path {
                $script:testPathCallCount++
                # exists before deletion, gone after - the real happy-path shape.
                $script:testPathCallCount -eq 1
            }

            Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Pluto for Channels"; portable = $true })

            Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Pluto for Channels uninstalled."
            }
            Remove-Variable -Name testPathCallCount -Scope Script -ErrorAction SilentlyContinue
        }

        It "logs a warning instead of a false success message when the install folder still exists after deletion" {
            # Regression guard for the actual reported bug: the uninstall logged success while a
            # locked file inside the install folder (from a process the earlier Path-only match
            # missed) silently made Remove-Item's own deletion incomplete - a non-terminating
            # per-item error, not one this function's try/catch ever saw - so "Show Installed
            # Apps" kept finding the app and its tray icon kept running, despite the "uninstalled"
            # log line claiming otherwise. Test-Path returning $true both before AND after
            # Remove-Item is exactly that shape.
            Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Pluto for Channels"; portable = $true })

            Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq "WARN" -and $Message -like "*uninstall incomplete*still exists*"
            }
            Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter {
                $Message -eq "Pluto for Channels uninstalled."
            }
        }

        It "reports the uninstall milestone via ProgressCallback" {
            $messages = [System.Collections.Generic.List[string]]::new()

            Uninstall-WinUtilProgramGithub -Packages @([pscustomobject]@{ content = "Pluto for Channels"; portable = $true }) -ProgressCallback {
                param($message) $messages.Add($message)
            }

            $messages | Should -Be @("Uninstalling Pluto for Channels...")
        }
    }
}
