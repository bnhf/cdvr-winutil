#===========================================================================
# Tests - Install prerequisite checks (WSL2, hardware virtualization, requires)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilWSLFeatureEnabled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilVirtualizationFirmwareEnabled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilProgramInstalled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPrerequisites.ps1")

    function Test-WinUtilWSLDistroInstalled { param($Distro) $false }
    function Show-WinUtilMessage { param($Message, $Title, $Button, $Icon) }
    function Write-WinUtilLog { }
}

Describe "Test-WinUtilWSLFeatureEnabled" {
    It "returns true only when both required optional features are enabled" {
        Mock Get-WindowsOptionalFeature {
            param($Online, $FeatureName)
            [pscustomobject]@{ State = "Enabled" }
        }
        Test-WinUtilWSLFeatureEnabled | Should -Be $true
    }

    It "returns false when VirtualMachinePlatform is missing even if the base WSL feature is enabled" {
        Mock Get-WindowsOptionalFeature {
            param($Online, $FeatureName)
            if ($FeatureName -eq "VirtualMachinePlatform") {
                [pscustomobject]@{ State = "Disabled" }
            } else {
                [pscustomobject]@{ State = "Enabled" }
            }
        }
        Test-WinUtilWSLFeatureEnabled | Should -Be $false
    }

    It "returns false when the query fails" {
        Mock Get-WindowsOptionalFeature { throw "not supported on this SKU" }
        Test-WinUtilWSLFeatureEnabled | Should -Be $false
    }
}

Describe "Test-WinUtilVirtualizationFirmwareEnabled" {
    It "returns true when the CIM property reports enabled" {
        Mock Get-CimInstance { [pscustomobject]@{ VirtualizationFirmwareEnabled = $true } }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -Be $true
    }

    It "returns false when the CIM property reports disabled" {
        Mock Get-CimInstance { [pscustomobject]@{ VirtualizationFirmwareEnabled = $false } }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -Be $false
    }

    It "returns null (not false) when the property is unavailable, rather than assuming it's disabled" {
        Mock Get-CimInstance { [pscustomobject]@{ VirtualizationFirmwareEnabled = $null } }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -BeNullOrEmpty
    }

    It "returns null (not false) when the CIM query itself fails" {
        Mock Get-CimInstance { throw "WMI unavailable" }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -BeNullOrEmpty
    }
}

Describe "Resolve-WinUtilPrerequisites virtualization gate" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = [pscustomobject]@{
                applicationsHashtable = @{
                    WPFInstallwsl2 = [pscustomobject]@{ content = "WSL2"; installType = "wslFeature" }
                    WPFInstalldockerdesktop = [pscustomobject]@{ content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2") }
                }
            }
        })
        Mock Test-WinUtilProgramInstalled { $false }
        Mock Write-WinUtilLog { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "drops WSL2 and everything requiring it, without prompting, when virtualization is disabled" {
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $false }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::OK }

        $wsl2 = [pscustomobject]@{ Key = "wsl2"; content = "WSL2"; installType = "wslFeature" }
        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2") }

        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($wsl2, $docker)

        $resolved | Should -BeNullOrEmpty
        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter { $Button -eq ([System.Windows.MessageBoxButton]::OK) }
    }

    It "does not gate on virtualization when nothing in the selection needs WSL2" {
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $false }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::OK }

        $chrome = [pscustomobject]@{ Key = "chrome"; content = "Chrome"; winget = "Google.Chrome.EXE" }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($chrome)

        $resolved | Should -HaveCount 1
        Should -Invoke -CommandName Show-WinUtilMessage -Times 0 -Exactly
    }

    It "proceeds to the normal missing-prerequisite prompt when virtualization status is unknown" {
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $null }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }

        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2") }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($docker)

        # wsl2 gets pulled in via the normal Yes/No prerequisite flow, not dropped
        @($resolved.Key) | Should -Contain "wsl2"
        @($resolved.Key) | Should -Contain "dockerdesktop"
    }

    It "proceeds normally when virtualization is confirmed enabled" {
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $true }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }

        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2") }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($docker)

        @($resolved.Key) | Should -Contain "wsl2"
        @($resolved.Key) | Should -Contain "dockerdesktop"
    }
}
