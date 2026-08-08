#===========================================================================
# Tests - Install prerequisite checks (WSL2, hardware virtualization, requires)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilWSLFeatureEnabled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilVirtualizationFirmwareEnabled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilProgramInstalled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPrerequisites.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPackagePrompts.ps1")

    function Test-WinUtilWSLDistroInstalled { param($Distro) $false }
    function Show-WinUtilMessage { param($Message, $Title, $Button, $Icon) }
    function Write-WinUtilLog { }
}

Describe "Test-WinUtilWSLFeatureEnabled" {
    It "returns true only when both required optional features are enabled" {
        Mock Get-WindowsOptionalFeature {
            @(
                [pscustomobject]@{ FeatureName = "Microsoft-Windows-Subsystem-Linux"; State = "Enabled" }
                [pscustomobject]@{ FeatureName = "VirtualMachinePlatform"; State = "Enabled" }
            )
        }
        Test-WinUtilWSLFeatureEnabled | Should -Be $true
    }

    It "returns false when VirtualMachinePlatform is missing even if the base WSL feature is enabled" {
        Mock Get-WindowsOptionalFeature {
            @(
                [pscustomobject]@{ FeatureName = "Microsoft-Windows-Subsystem-Linux"; State = "Enabled" }
                [pscustomobject]@{ FeatureName = "VirtualMachinePlatform"; State = "Disabled" }
            )
        }
        Test-WinUtilWSLFeatureEnabled | Should -Be $false
    }

    It "returns false when the query fails" {
        Mock Get-WindowsOptionalFeature { throw "not supported on this SKU" }
        Test-WinUtilWSLFeatureEnabled | Should -Be $false
    }

    It "queries Get-WindowsOptionalFeature exactly once, not once per feature" {
        # Regression guard: Get-WindowsOptionalFeature is DISM-backed and slow regardless of
        # how narrow -FeatureName is, and Resolve-WinUtilPrerequisites calls this synchronously
        # on the UI thread - calling it once per feature made the app appear to hang while
        # installing anything that requires WSL2 (e.g. Docker Desktop).
        Mock Get-WindowsOptionalFeature {
            @(
                [pscustomobject]@{ FeatureName = "Microsoft-Windows-Subsystem-Linux"; State = "Enabled" }
                [pscustomobject]@{ FeatureName = "VirtualMachinePlatform"; State = "Enabled" }
            )
        }
        Test-WinUtilWSLFeatureEnabled | Out-Null
        Should -Invoke -CommandName Get-WindowsOptionalFeature -Times 1 -Exactly
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

    It "returns an empty array rather than `$null` when everything is dropped, matching a real production crash report" {
        # PowerShell unwraps a returned empty array to $null across a function-return boundary
        # unless guarded - this reproduces the exact reported failure: a solo Docker Desktop
        # selection whose only prerequisite (WSL2) is declined/blocked, leaving nothing queued.
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $false }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::OK }

        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2") }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($docker)

        ($null -eq $resolved) | Should -BeFalse
        $resolved.Count | Should -Be 0

        # Invoke-WPFInstall.ps1 immediately feeds this into Resolve-WinUtilPackagePrompts, which
        # requires a non-null [object[]] - this used to throw
        # ParameterArgumentValidationErrorNullNotAllowed here.
        { Resolve-WinUtilPackagePrompts -PackagesToInstall $resolved } | Should -Not -Throw
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
