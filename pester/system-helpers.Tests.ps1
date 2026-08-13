#===========================================================================
# Tests - System Helper Functions
#===========================================================================

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilCurrentSystem.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilProgramInstalled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Find-WinUtilAppLaunchTarget.ps1")
    . (Join-Path $script:repoRoot "functions\private\Set-WinUtilRegistry.ps1")
    . (Join-Path $script:repoRoot "functions\private\Set-WinUtilService.ps1")

    function winget {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }
    function choco {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }
    function Test-WinUtilWSLFeatureEnabled { $false }
    function Test-WinUtilWSLDistroInstalled { param($Distro) $false }
    function Test-WinUtilWSLCommandInstalled { param($Distro, $InstallCheckCommand) $false }
    function Test-WinUtilWebUIReachable { param($Url) $false }
    function Get-WinUtilProgramUninstallString { param($DisplayNamePattern) [pscustomobject]@{ UninstallString = $null; Reason = "not found" } }
    function Test-WinUtilNpmPackageInstalled { param($NpmPackage) $false }
    function Test-WinUtilPortableGithubInstalled { param($Name, $AssetPattern) $false }
    function Set-WinUtilTweaksProgressIndicator { param($Visible, $Label, $Percent) }
    function Write-WinUtilLog { }
}

Describe "Invoke-WinUtilCurrentSystem installed apps" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = [pscustomobject]@{
                applicationsHashtable = @{
                    WPFInstallGit = [pscustomobject]@{ winget = "Git.Git"; choco = "git" }
                    WPFInstallChatGPT = [pscustomobject]@{ winget = "msstore:9NT1R1C2HH7J"; choco = "na" }
                    WPFInstallMissing = [pscustomobject]@{ winget = "Git"; choco = "missing" }
                }
            }
        })

        # Per-app targeted lookups: Invoke-WinUtilCurrentSystem now calls
        # "winget list --id <id> --exact ..." once per app (via Test-WinUtilProgramInstalled)
        # instead of one bulk "winget list" scanned with a regex, since the bulk listing's
        # Id/Source columns are unreliable for apps that self-update outside of winget.
        Mock winget {
            $script:wingetCalls += , @($Arguments)
            $ArgumentsList = @($Arguments)
            $idIndex = [array]::IndexOf($ArgumentsList, "--id")
            $requestedId = if ($idIndex -ge 0) { $ArgumentsList[$idIndex + 1] } else { $null }

            $global:LASTEXITCODE = 0
            switch ($requestedId) {
                "Git.Git" { return @("Name  Id  Version  Source", "----", "Git  Git.Git  2.0  winget") }
                "9NT1R1C2HH7J" { return @("Name  Id  Version  Source", "----", "ChatGPT  9NT1R1C2HH7J  1.0  msstore") }
                default { return @("No installed package found matching input criteria.") }
            }
        }
        Mock choco {
            $script:chocoArguments = @($Arguments)
            @("Chocolatey v2", "git 2.0", "2 packages installed.")
        }
        Mock Set-WinUtilTweaksProgressIndicator { }
        $script:wingetCalls = @()
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name wingetCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name chocoArguments -Scope Script -ErrorAction SilentlyContinue
    }

    It "matches single standard and Microsoft Store package IDs" {
        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -HaveCount 2
        $result | Should -Contain "WPFInstallGit"
        $result | Should -Contain "WPFInstallChatGPT"
        $result | Should -Not -Contain "WPFInstallMissing"
        # 1 upfront sanity check + 1 targeted --id --exact lookup per app with a winget id
        Should -Invoke -CommandName winget -Times 4 -Exactly
        $script:wingetCalls | Where-Object { $_ -contains "--id" -and $_ -contains "Git.Git" } | Should -HaveCount 1
        $script:wingetCalls | Where-Object { $_ -contains "--id" -and $_ -contains "9NT1R1C2HH7J" } | Should -HaveCount 1
        $script:wingetCalls | Where-Object { $_ -contains "--id" -and $_ -contains "Git" } | Should -HaveCount 1
    }

    It "fails promptly when Winget cannot list applications" {
        Mock winget {
            $global:LASTEXITCODE = 1
            "winget failed"
        }

        { Invoke-WinUtilCurrentSystem -CheckBox "winget" } | Should -Throw "winget list failed with exit code 1."
    }

    It "matches the primary Chocolatey package ID in one list call" {
        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "choco")

        $result | Should -Be @("WPFInstallGit")
        Should -Invoke -CommandName choco -Times 1 -Exactly
        $script:chocoArguments | Should -Be @("list")
    }

    It "reports per-app progress on the shared progress indicator while checking" {
        Invoke-WinUtilCurrentSystem -CheckBox "winget" | Out-Null

        # 1 initial "0/N" call + 1 per app checked (3) + 1 final "finished" call
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 5 -Exactly
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -ParameterFilter {
            $Visible -eq $true -and $Percent -eq 100 -and $Label -eq "Finished checking installed apps"
        } -Times 1 -Exactly
    }
}

Describe "Invoke-WinUtilCurrentSystem WSL detection" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = [pscustomobject]@{
                applicationsHashtable = @{
                    WPFInstallwsl2 = [pscustomobject]@{ installType = "wslFeature" }
                    WPFInstalldebian = [pscustomobject]@{ installType = "wslDistro"; distro = "Debian" }
                    WPFInstallubuntu = [pscustomobject]@{ installType = "wslDistro"; distro = "Ubuntu" }
                }
            }
        })
        Mock winget {
            $global:LASTEXITCODE = 0
            @("No installed package found matching input criteria.")
        }
        Mock choco { @() }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "detects an enabled WSL feature and an installed distro, independent of package-manager preference" {
        Mock Test-WinUtilWSLFeatureEnabled { $true }
        Mock Test-WinUtilWSLDistroInstalled { param($Distro) $Distro -eq "Debian" }

        $wingetResult = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")
        $wingetResult | Should -Contain "WPFInstallwsl2"
        $wingetResult | Should -Contain "WPFInstalldebian"
        $wingetResult | Should -Not -Contain "WPFInstallubuntu"

        $chocoResult = @(Invoke-WinUtilCurrentSystem -CheckBox "choco")
        $chocoResult | Should -Contain "WPFInstallwsl2"
        $chocoResult | Should -Contain "WPFInstalldebian"
    }

    It "reports nothing when the WSL feature and distros are absent" {
        Mock Test-WinUtilWSLFeatureEnabled { $false }
        Mock Test-WinUtilWSLDistroInstalled { $false }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")
        $result | Should -BeNullOrEmpty
    }
}

Describe "Invoke-WinUtilCurrentSystem direct/github/wslCommand detection" {
    # Regression guard: this whole switch case block didn't exist before - "direct" (Channels
    # DVR), "github" (Clicker), and "wslCommand" (Olivetin) install types were never handled by
    # "Show Installed Apps" at all, so those checkboxes could never get checked no matter what
    # was actually installed.
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = [pscustomobject]@{
                applicationsHashtable = @{
                    WPFInstallchannelsdvr = [pscustomobject]@{ installType = "direct"; content = "Channels DVR"; webui = "http://localhost:8089" }
                    WPFInstallrustdvr = [pscustomobject]@{ installType = "github"; content = "Clicker"; webui = $null }
                    WPFInstallplutoforchannels = [pscustomobject]@{ installType = "github"; content = "Pluto for Channels"; webui = $null; portable = $true; assetPattern = "PlutoForChannels*.exe" }
                    WPFInstallolivetin = [pscustomobject]@{ installType = "wslCommand"; distro = "Debian"; installCheckCommand = "docker inspect olivetin-ezstart" }
                    WPFInstallstreamlinkmanager = [pscustomobject]@{ installType = "streamLinkManager" }
                    WPFInstallprismcast = [pscustomobject]@{ installType = "npm"; content = "Prismcast"; npmPackage = "prismcast" }
                }
            }
        })
        Mock winget {
            $global:LASTEXITCODE = 0
            @("No installed package found matching input criteria.")
        }
        Mock choco { @() }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "detects a direct-install package via its webui reachability" {
        Mock Test-WinUtilWebUIReachable { $true } -ParameterFilter { $Url -eq "http://localhost:8089" }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Contain "WPFInstallchannelsdvr"
        Should -Invoke -CommandName Test-WinUtilWebUIReachable -Times 1 -Exactly -ParameterFilter { $Url -eq "http://localhost:8089" }
    }

    It "does not report a direct-install package as installed when neither webui nor Add/Remove Programs match" {
        Mock Test-WinUtilWebUIReachable { $false }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Not -Contain "WPFInstallchannelsdvr"
    }

    It "detects a github-install package via Add/Remove Programs even when it has no webui declared" {
        # Regression guard for a real production bug: this used to be webui-only, so a
        # github-install package without one (Clicker, and 3 of the other 5 github entries in
        # the real catalog) could never be detected as installed no matter what was actually on
        # disk - confirmed live, Clicker registers a normal Windows uninstaller, so the same
        # Add/Remove Programs lookup Uninstall-WinUtilProgramGithub uses to uninstall it works
        # here too, as a second, independent signal alongside webui.
        Mock Get-WinUtilProgramUninstallString {
            [pscustomobject]@{ UninstallString = '"C:\Program Files\Clicker\unins000.exe"'; Reason = $null }
        } -ParameterFilter { $DisplayNamePattern -eq "*Clicker*" }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Contain "WPFInstallrustdvr"
    }

    It "does not report a github-install package as installed when neither webui nor Add/Remove Programs match" {
        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Not -Contain "WPFInstallrustdvr"
    }

    It "detects a portable github-install package via its fixed install folder, with no webui or Add/Remove Programs entry" {
        # Regression guard for the actual reported bug: Pluto for Channels never registers in
        # Add/Remove Programs (confirmed via its own repo docs) and its webui is only reachable
        # while the app is actively running - both of the other two "github" signals go blind
        # for an installed-but-not-currently-running portable app. This third signal, checking
        # Install-WinUtilProgramGithub's own fixed per-app install folder, is what fixes that.
        Mock Test-WinUtilPortableGithubInstalled {
            $true
        } -ParameterFilter { $Name -eq "Pluto for Channels" -and $AssetPattern -eq "PlutoForChannels*.exe" }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Contain "WPFInstallplutoforchannels"
    }

    It "does not report a portable github-install package as installed when its install folder check fails" {
        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Not -Contain "WPFInstallplutoforchannels"
    }

    It "detects a wslCommand package via its installCheckCommand" {
        Mock Test-WinUtilWSLCommandInstalled { $true } -ParameterFilter {
            $Distro -eq "Debian" -and $InstallCheckCommand -eq "docker inspect olivetin-ezstart"
        }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Contain "WPFInstallolivetin"
    }

    It "does not report a wslCommand package as installed when its installCheckCommand fails" {
        Mock Test-WinUtilWSLCommandInstalled { $false }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Not -Contain "WPFInstallolivetin"
    }

    It "detects an npm package via 'npm list -g'" {
        # Regression guard: this installType had no case at all - Prismcast (currently the only
        # npm-type entry) could never be shown as installed by "Show Installed Apps", the same
        # class of gap "direct"/"github" had before their own fix.
        Mock Test-WinUtilNpmPackageInstalled { $true } -ParameterFilter { $NpmPackage -eq "prismcast" }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Contain "WPFInstallprismcast"
    }

    It "does not report an npm package as installed when 'npm list -g' doesn't find it" {
        Mock Test-WinUtilNpmPackageInstalled { $false }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Not -Contain "WPFInstallprismcast"
    }

    It "detects a streamLinkManager package via its fixed install path" {
        # Regression guard: Streaming Library Manager installed to a real, fixed location but
        # "Show Installed Apps" never checked for it - this installType had no case at all.
        Mock Test-Path { $true } -ParameterFilter { $Path -like "*StreamLinkManager\slm.exe" }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Contain "WPFInstallstreamlinkmanager"
    }

    It "does not report streamLinkManager as installed when its exe is not present" {
        Mock Test-Path { $false } -ParameterFilter { $Path -like "*StreamLinkManager\slm.exe" }

        $result = @(Invoke-WinUtilCurrentSystem -CheckBox "winget")

        $result | Should -Not -Contain "WPFInstallstreamlinkmanager"
    }
}

Describe "Find-WinUtilAppLaunchTarget" {
    BeforeEach {
        Mock Get-StartApps {
            @(
                [pscustomobject]@{ Name = "Google Chrome"; AppID = "Chrome" }
                [pscustomobject]@{ Name = "Chrome Remote Desktop"; AppID = "Chrome._crx_cmkncekebbplodngbpllndjkfo" }
                [pscustomobject]@{ Name = "Firefox"; AppID = "org.mozilla.firefox" }
                [pscustomobject]@{ Name = "Firefox Private Browsing"; AppID = "308046B0AF4A39CB;PrivateBrowsingAUMID" }
                [pscustomobject]@{ Name = "Terminal"; AppID = "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App" }
            )
        }
    }

    It "prefers an exact name match over a longer substring match" {
        Find-WinUtilAppLaunchTarget -AppName "Firefox" | Should -Be "shell:AppsFolder\org.mozilla.firefox"
    }

    It "picks the closest-length substring match when there is no exact match" {
        # "Chrome" substring-matches both "Google Chrome" and the unrelated "Chrome Remote
        # Desktop" - the closest-length entry ("Google Chrome") should win, not whichever
        # Get-StartApps happens to enumerate first.
        Find-WinUtilAppLaunchTarget -AppName "Chrome" | Should -Be "shell:AppsFolder\Chrome"
    }

    It "matches an MSIX-packaged app that has no classic shortcut" {
        Find-WinUtilAppLaunchTarget -AppName "Windows Terminal" | Should -Be "shell:AppsFolder\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
    }

    It "returns null when nothing matches" {
        Find-WinUtilAppLaunchTarget -AppName "Totally Fictional App" | Should -BeNullOrEmpty
    }
}

Describe "Set-WinUtilRegistry" {
    BeforeEach {
        $script:testPathResults = @{}

        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Write-WinUtilLog { }
        Mock Test-Path {
            param([string]$Path)

            if ($script:testPathResults.ContainsKey($Path)) {
                return $script:testPathResults[$Path]
            }

            throw "Unexpected Test-Path call: $Path"
        }
        Mock New-PSDrive { }
        Mock New-Item { }
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
    }

    It "creates a missing registry path before setting a value" {
        $registryPath = "HKCU:\Software\WinUtilTest"
        $script:testPathResults["HKU:\"] = $true
        $script:testPathResults[$registryPath] = $false

        Set-WinUtilRegistry -Path $registryPath -Name "Enabled" -Type "DWord" -Value "1"

        Should -Invoke -CommandName New-PSDrive -Times 0 -Exactly
        Should -Invoke -CommandName New-Item -Times 1 -Exactly -ParameterFilter {
            $Path -eq $registryPath -and $Force -eq $true -and $ErrorAction -eq "Stop"
        }
        Should -Invoke -CommandName Set-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq $registryPath -and
                $Name -eq "Enabled" -and
                $Type -eq "DWord" -and
                $Value -eq "1" -and
                $Force -eq $true -and
                $ErrorAction -eq "Stop"
        }
        Should -Invoke -CommandName Remove-ItemProperty -Times 0 -Exactly
    }

    It "creates the HKU PSDrive when it is missing" {
        $registryPath = "HKCU:\Software\WinUtilTest"
        $script:testPathResults["HKU:\"] = $false
        $script:testPathResults[$registryPath] = $true

        Set-WinUtilRegistry -Path $registryPath -Name "Enabled" -Type "DWord" -Value "1"

        Should -Invoke -CommandName New-PSDrive -Times 1 -Exactly -ParameterFilter {
            $PSProvider -eq "Registry" -and
                $Name -eq "HKU" -and
                $Root -eq "HKEY_USERS"
        }
        Should -Invoke -CommandName New-Item -Times 0 -Exactly
        Should -Invoke -CommandName Set-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq $registryPath -and $Name -eq "Enabled" -and $Type -eq "DWord" -and $Value -eq "1"
        }
    }

    It "removes a registry value when requested" {
        $registryPath = "HKLM:\Software\WinUtilTest"
        $script:testPathResults["HKU:\"] = $true
        $script:testPathResults[$registryPath] = $true

        Set-WinUtilRegistry -Path $registryPath -Name "ObsoleteValue" -Type "String" -Value "<RemoveEntry>"

        Should -Invoke -CommandName Set-ItemProperty -Times 0 -Exactly
        Should -Invoke -CommandName Remove-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq $registryPath -and
                $Name -eq "ObsoleteValue" -and
                $Force -eq $true -and
                $ErrorAction -eq "Stop"
        }
    }
}

Describe "Set-WinUtilService" {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Write-WinUtilLog { }
        Mock Get-Service { }
        Mock Set-Service { }
    }

    It "sets the startup type for an existing service" {
        Mock Get-Service {
            [pscustomobject]@{
                Name = "DiagTrack"
                StartType = "Automatic"
            }
        } -ParameterFilter { $Name -eq "DiagTrack" -and $ErrorAction -eq "Stop" }

        Set-WinUtilService -Name "DiagTrack" -StartupType "Disabled"

        Should -Invoke -CommandName Get-Service -Times 1 -Exactly -ParameterFilter {
            $Name -eq "DiagTrack" -and $ErrorAction -eq "Stop"
        }
        Should -Invoke -CommandName Set-Service -Times 1 -Exactly -ParameterFilter {
            $StartupType -eq "Disabled" -and $ErrorAction -eq "Stop"
        }
    }

    It "does not change a service that already has the requested startup type" {
        Mock Get-Service {
            [pscustomobject]@{
                Name = "DiagTrack"
                StartType = "Disabled"
            }
        } -ParameterFilter { $Name -eq "DiagTrack" -and $ErrorAction -eq "Stop" }

        Set-WinUtilService -Name "DiagTrack" -StartupType "Disabled"

        Should -Invoke -CommandName Get-Service -Times 1 -Exactly
        Should -Invoke -CommandName Set-Service -Times 0 -Exactly
    }

    It "does not call Set-Service when the service is missing" {
        Mock Get-Service {
            $exception = [Microsoft.PowerShell.Commands.ServiceCommandException]::new("Cannot find any service with service name '$Name'.")
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception,
                "NoServiceFoundForGivenName,Microsoft.PowerShell.Commands.GetServiceCommand",
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $Name
            )
            throw $errorRecord
        } -ParameterFilter { $Name -eq "MissingService" -and $ErrorAction -eq "Stop" }

        Set-WinUtilService -Name "MissingService" -StartupType "Disabled"

        Should -Invoke -CommandName Get-Service -Times 1 -Exactly -ParameterFilter {
            $Name -eq "MissingService" -and $ErrorAction -eq "Stop"
        }
        Should -Invoke -CommandName Set-Service -Times 0 -Exactly
        Should -Invoke -CommandName Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -eq "Service MissingService was not found."
        }
    }
}
