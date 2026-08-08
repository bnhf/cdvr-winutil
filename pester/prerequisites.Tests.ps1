#===========================================================================
# Tests - Install prerequisite checks (WSL2, hardware virtualization, requires)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilWithTimeout.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilWSLFeatureEnabled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilVirtualizationFirmwareEnabled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilProgramInstalled.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPrerequisites.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPackagePrompts.ps1")

    function Test-WinUtilWSLDistroInstalled { param($Distro) $false }
    function Show-WinUtilMessage { param($Message, $Title, $Button, $Icon) }
    function Write-WinUtilLog { }
}

# Test-WinUtilWSLFeatureEnabled and Test-WinUtilVirtualizationFirmwareEnabled now run their real
# logic (Get-WindowsOptionalFeature / Get-CimInstance) inside Invoke-WinUtilWithTimeout's own
# isolated [PowerShell]::Create() runspace, so Pester's Mock - which shadows functions only in
# the runspace/scope it's running in - can no longer reach the inner cmdlets. These tests mock
# Invoke-WinUtilWithTimeout itself instead, verifying the wrapper calls it with sane parameters
# (a scriptblock, a bounded timeout, the right fallback default) and passes its result straight
# through. Invoke-WinUtilWithTimeout's own correctness (executes the scriptblock, honors the
# timeout, returns -DefaultValue on timeout/error) is covered separately below.
Describe "Test-WinUtilWSLFeatureEnabled" {
    It "returns whatever Invoke-WinUtilWithTimeout produces" {
        Mock Invoke-WinUtilWithTimeout { $true }
        Test-WinUtilWSLFeatureEnabled | Should -Be $true

        Mock Invoke-WinUtilWithTimeout { $false }
        Test-WinUtilWSLFeatureEnabled | Should -Be $false
    }

    It "runs bounded by a timeout, defaulting to false rather than hanging the caller" {
        Mock Invoke-WinUtilWithTimeout { $false }
        Test-WinUtilWSLFeatureEnabled | Out-Null
        Should -Invoke -CommandName Invoke-WinUtilWithTimeout -Times 1 -Exactly -ParameterFilter {
            $DefaultValue -eq $false -and $TimeoutSeconds -gt 0 -and $TimeoutSeconds -le 30 -and $ScriptBlock -ne $null
        }
    }

    It "checks both required optional features in a single Get-WindowsOptionalFeature call, not once per feature" {
        # Regression guard: Get-WindowsOptionalFeature is DISM-backed and slow regardless of
        # how narrow -FeatureName is, and Resolve-WinUtilPrerequisites calls this synchronously
        # on the UI thread - calling it once per feature made the app appear to hang while
        # installing anything that requires WSL2 (e.g. Docker Desktop). Runs the wrapper's real
        # scriptblock directly (bypassing the runspace boundary) against a mocked cmdlet, since
        # that's the only way to observe call count from inside Pester.
        Mock Get-WindowsOptionalFeature {
            @(
                [pscustomobject]@{ FeatureName = "Microsoft-Windows-Subsystem-Linux"; State = "Enabled" }
                [pscustomobject]@{ FeatureName = "VirtualMachinePlatform"; State = "Enabled" }
            )
        }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock }
        Test-WinUtilWSLFeatureEnabled | Should -Be $true
        Should -Invoke -CommandName Get-WindowsOptionalFeature -Times 1 -Exactly
    }
}

Describe "Test-WinUtilVirtualizationFirmwareEnabled" {
    It "returns whatever Invoke-WinUtilWithTimeout produces" {
        Mock Invoke-WinUtilWithTimeout { $true }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -Be $true

        Mock Invoke-WinUtilWithTimeout { $false }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -Be $false

        Mock Invoke-WinUtilWithTimeout { $null }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -BeNullOrEmpty
    }

    It "runs bounded by a timeout, defaulting to null (unknown) rather than hanging the caller" {
        # A timeout here must not be treated as "disabled" - only a definite $false should block
        # anything, per Resolve-WinUtilPrerequisites' virtualization gate.
        Mock Invoke-WinUtilWithTimeout { $null }
        Test-WinUtilVirtualizationFirmwareEnabled | Out-Null
        Should -Invoke -CommandName Invoke-WinUtilWithTimeout -Times 1 -Exactly -ParameterFilter {
            $null -eq $DefaultValue -and $TimeoutSeconds -gt 0 -and $TimeoutSeconds -le 30 -and $ScriptBlock -ne $null
        }
    }

    It "returns null (not false) when the CIM property is unavailable or the query fails, via its real scriptblock" {
        # Runs the wrapper's real scriptblock directly (bypassing the runspace boundary) to
        # verify the inner logic itself, since Invoke-WinUtilWithTimeout's own execution is
        # covered separately below.
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock }

        Mock Get-CimInstance { [pscustomobject]@{ VirtualizationFirmwareEnabled = $null } }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -BeNullOrEmpty

        Mock Get-CimInstance { throw "WMI unavailable" }
        Test-WinUtilVirtualizationFirmwareEnabled | Should -BeNullOrEmpty
    }
}

Describe "Invoke-WinUtilWithTimeout" {
    It "returns the scriptblock's result when it completes within the timeout" {
        Invoke-WinUtilWithTimeout -TimeoutSeconds 5 -ScriptBlock { 1 + 1 } | Should -Be 2
    }

    It "passes -ArgumentList through to the scriptblock" {
        Invoke-WinUtilWithTimeout -TimeoutSeconds 5 -ArgumentList @("hello", 42) -ScriptBlock {
            param($a, $b)
            "$a-$b"
        } | Should -Be "hello-42"
    }

    It "returns -DefaultValue instead of blocking when the scriptblock exceeds the timeout" {
        $result = Invoke-WinUtilWithTimeout -TimeoutSeconds 1 -DefaultValue "TIMED_OUT" -ScriptBlock {
            Start-Sleep -Seconds 10
            "SHOULD_NOT_SEE_THIS"
        }
        $result | Should -Be "TIMED_OUT"
    }

    It "returns -DefaultValue when the scriptblock throws" {
        $result = Invoke-WinUtilWithTimeout -TimeoutSeconds 5 -DefaultValue "ERROR_DEFAULT" -ScriptBlock {
            throw "boom"
        }
        $result | Should -Be "ERROR_DEFAULT"
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
