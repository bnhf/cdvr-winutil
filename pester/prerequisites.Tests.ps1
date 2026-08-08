#===========================================================================
# Tests - Install prerequisite checks (WSL2, hardware virtualization, requires)
#===========================================================================

BeforeAll {
    # In the real app, [System.Windows.MessageBoxButton]/[System.Windows.MessageBoxResult]
    # (used throughout Resolve-WinUtilPrerequisites and these tests) resolve for free because
    # scripts/main.ps1 references [Windows.Markup.XamlReader] to load the UI long before any
    # dialog is shown, which pulls in PresentationFramework as a side effect. Nothing here loads
    # XAML, so without this, whether that type resolves depends on whether some unrelated test
    # file happened to run first in the same pwsh session and loaded it incidentally - loading it
    # explicitly makes this file's results deterministic regardless of run order.
    Add-Type -AssemblyName PresentationFramework

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
    function wsl {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }
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

    It "returns false without querying DISM when WSL2 was uninstalled through WinUtil this session" {
        # Regression guard for a real report: "wsl --uninstall" deliberately does not disable
        # the underlying Microsoft-Windows-Subsystem-Linux/VirtualMachinePlatform optional
        # features, so DISM alone would still say "Enabled" right after uninstalling WSL2
        # through WinUtil - incorrectly treating it as already usable and skipping the
        # restart-required gate for anything selected afterward in the same app session.
        $script:sync = [Hashtable]::Synchronized(@{ WSLRuntimeUninstalled = $true })
        Mock Invoke-WinUtilWithTimeout { $true }

        Test-WinUtilWSLFeatureEnabled | Should -Be $false
        Should -Invoke -CommandName Invoke-WinUtilWithTimeout -Times 0 -Exactly

        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "falls through to the real DISM-backed check when the session flag is absent or false" {
        $script:sync = [Hashtable]::Synchronized(@{ WSLRuntimeUninstalled = $false })
        Mock Invoke-WinUtilWithTimeout { $true }

        Test-WinUtilWSLFeatureEnabled | Should -Be $true
        Should -Invoke -CommandName Invoke-WinUtilWithTimeout -Times 1 -Exactly

        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
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
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock }
        Test-WinUtilWSLFeatureEnabled | Should -Be $true
        Should -Invoke -CommandName Get-WindowsOptionalFeature -Times 1 -Exactly
    }

    It "returns false when wsl --status reports a non-zero exit code, even though the optional features are enabled" {
        # Regression guard for a real report: right after uninstalling WSL2 through WinUtil in a
        # PREVIOUS app session (so the WSLRuntimeUninstalled session flag no longer applies),
        # Show Installed Apps still reported WSL2 as installed, even though "wsl --status" said
        # "The Windows Subsystem for Linux is not installed" and exited with code 50 - confirmed
        # live on the affected machine. The optional features alone don't catch this, since
        # "wsl --uninstall" doesn't disable them.
        Mock Get-WindowsOptionalFeature {
            @(
                [pscustomobject]@{ FeatureName = "Microsoft-Windows-Subsystem-Linux"; State = "Enabled" }
                [pscustomobject]@{ FeatureName = "VirtualMachinePlatform"; State = "Enabled" }
            )
        }
        Mock wsl { $global:LASTEXITCODE = 50 }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock }

        Test-WinUtilWSLFeatureEnabled | Should -Be $false
    }

    It "runs wsl --status once, not once per feature, alongside the single Get-WindowsOptionalFeature call" {
        # Regression guard: both checks share the one Invoke-WinUtilWithTimeout call rather than
        # each getting their own - two bounded external calls would double the worst-case
        # latency of a function Resolve-WinUtilPrerequisites calls synchronously on the UI
        # thread.
        Mock Get-WindowsOptionalFeature {
            @(
                [pscustomobject]@{ FeatureName = "Microsoft-Windows-Subsystem-Linux"; State = "Enabled" }
                [pscustomobject]@{ FeatureName = "VirtualMachinePlatform"; State = "Enabled" }
            )
        }
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock }

        Test-WinUtilWSLFeatureEnabled | Should -Be $true
        Should -Invoke -CommandName wsl -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-WinUtilWithTimeout -Times 1 -Exactly
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

    It "calls -OnWaiting periodically while a long-running scriptblock is still in progress" {
        # Regression guard for a real report: a WSL distro install that was genuinely working
        # (and did finish successfully) produced zero console/progress feedback for its full
        # 5-minute timeout window, reading as a stalled/broken app rather than a slow-but-working
        # one. -OnWaiting exists so long-running callers can surface periodic "still working"
        # feedback instead of one long silence.
        $script:pings = [System.Collections.Generic.List[int]]::new()
        $result = Invoke-WinUtilWithTimeout -TimeoutSeconds 6 -OnWaitingIntervalSeconds 2 -DefaultValue "TIMED_OUT" -OnWaiting {
            param($elapsedSeconds)
            $script:pings.Add($elapsedSeconds)
        } -ScriptBlock {
            Start-Sleep -Seconds 20
            "SHOULD_NOT_SEE_THIS"
        }

        $result | Should -Be "TIMED_OUT"
        @($script:pings) | Should -Be @(2, 4, 6)

        Remove-Variable -Name pings -Scope Script -ErrorAction SilentlyContinue
    }

    It "stops calling -OnWaiting once the scriptblock completes, and still returns its real result" {
        $script:pings2 = [System.Collections.Generic.List[int]]::new()
        $result = Invoke-WinUtilWithTimeout -TimeoutSeconds 10 -OnWaitingIntervalSeconds 2 -OnWaiting {
            param($elapsedSeconds)
            $script:pings2.Add($elapsedSeconds)
        } -ScriptBlock {
            Start-Sleep -Seconds 5
            "DONE"
        }

        $result | Should -Be "DONE"
        @($script:pings2) | Should -Be @(2, 4)

        Remove-Variable -Name pings2 -Scope Script -ErrorAction SilentlyContinue
    }

    It "behaves exactly as before for callers that don't supply -OnWaiting" {
        Invoke-WinUtilWithTimeout -TimeoutSeconds 5 -ScriptBlock { 1 + 1 } | Should -Be 2
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
        # Deterministic default so these tests don't depend on this machine's real WSL2 state
        # (Test-WinUtilWSLFeatureEnabled is otherwise unmocked here, which would hit real DISM).
        # "Not already enabled" is also the realistic default for these scenarios.
        Mock Test-WinUtilWSLFeatureEnabled { $false }
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

    It "pulls WSL2 into the queue via the normal Yes/No prompt when virtualization status is unknown, then defers Docker Desktop to the WSL2 restart gate" {
        # The missing-prereq Yes/No prompt and the WSL2-restart-gate's OK-only dialog both go
        # through Show-WinUtilMessage - differentiate by -Button, matching the "WSL2 restart
        # gate" Describe block below. WSL2 isn't already enabled in this scenario (that's why
        # the Yes/No prompt fires at all), so the restart gate correctly engages too - Docker
        # Desktop can't proceed in the same run as first-enabling WSL2.
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $null }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes } -ParameterFilter { $Button -eq ([System.Windows.MessageBoxButton]::YesNo) }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::OK } -ParameterFilter { $Button -eq ([System.Windows.MessageBoxButton]::OK) }

        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2") }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($docker)

        @($resolved.Key) | Should -Contain "wsl2"
        @($resolved.Key) | Should -Not -Contain "dockerdesktop"
    }

    It "pulls WSL2 into the queue when virtualization is confirmed enabled, then defers Docker Desktop to the WSL2 restart gate" {
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $true }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes } -ParameterFilter { $Button -eq ([System.Windows.MessageBoxButton]::YesNo) }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::OK } -ParameterFilter { $Button -eq ([System.Windows.MessageBoxButton]::OK) }

        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2") }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($docker)

        @($resolved.Key) | Should -Contain "wsl2"
        @($resolved.Key) | Should -Not -Contain "dockerdesktop"
    }
}

Describe "Resolve-WinUtilPrerequisites WSL2 restart gate" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = [pscustomobject]@{
                applicationsHashtable = @{
                    WPFInstallwsl2 = [pscustomobject]@{ content = "WSL2"; installType = "wslFeature" }
                    WPFInstalldebian = [pscustomobject]@{ content = "Debian"; installType = "wslDistro"; distro = "Debian"; requires = @("wsl2") }
                    WPFInstalldockerdesktop = [pscustomobject]@{ content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2", "debian") }
                }
            }
        })
        Mock Test-WinUtilProgramInstalled { $false }
        Mock Test-WinUtilWSLDistroInstalled { $false }
        Mock Test-WinUtilVirtualizationFirmwareEnabled { $true }
        Mock Write-WinUtilLog { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "installs WSL2 only and defers everything that needs it, when WSL2 isn't already enabled" {
        # Regression guard for a real report: WSL2 enabled successfully, but the immediately-
        # following Debian install failed - because enabling WSL2 for the first time typically
        # needs a restart before it's actually usable, so attempting a WSL2-dependent install in
        # the very same run is unreliable regardless of how correctly each step is implemented.
        Mock Test-WinUtilWSLFeatureEnabled { $false }
        # The missing-prereq Yes/No prompt and the new restart-required OK-only dialog both go
        # through Show-WinUtilMessage - differentiate by -Button so "Yes" only answers the
        # former (an OK-only dialog has no "Yes" result to return).
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes } -ParameterFilter { $Button -eq ([System.Windows.MessageBoxButton]::YesNo) }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::OK } -ParameterFilter { $Button -eq ([System.Windows.MessageBoxButton]::OK) }

        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2", "debian") }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($docker)

        @($resolved.Key) | Should -Contain "wsl2"
        @($resolved.Key) | Should -Not -Contain "debian"
        @($resolved.Key) | Should -Not -Contain "dockerdesktop"
        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter {
            $Title -eq "Restart required for WSL2" -and $Button -eq ([System.Windows.MessageBoxButton]::OK)
        }
    }

    It "proceeds normally in one run when WSL2 is already enabled" {
        # WSL2 already being enabled means there's nothing to queue for it specifically (it's
        # already installed, same as any other already-satisfied prerequisite) - what matters
        # here is that its dependents are NOT deferred, unlike the "not already enabled" case
        # above.
        Mock Test-WinUtilWSLFeatureEnabled { $true }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }

        $docker = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; requires = @("wsl2", "debian") }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($docker)

        @($resolved.Key) | Should -Contain "debian"
        @($resolved.Key) | Should -Contain "dockerdesktop"
        Should -Invoke -CommandName Show-WinUtilMessage -Times 0 -Exactly -ParameterFilter { $Title -eq "Restart required for WSL2" }
    }

    It "does not gate when nothing in the run actually needs a working WSL2" {
        Mock Test-WinUtilWSLFeatureEnabled { $false }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::OK }

        $wsl2 = [pscustomobject]@{ Key = "wsl2"; content = "WSL2"; installType = "wslFeature" }
        $resolved = Resolve-WinUtilPrerequisites -PackagesToInstall @($wsl2)

        @($resolved.Key) | Should -Contain "wsl2"
        Should -Invoke -CommandName Show-WinUtilMessage -Times 0 -Exactly
    }
}
