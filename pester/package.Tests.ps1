#===========================================================================
# Tests - Package Selection and Package Managers
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilSelectedPackages.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilPackageManager.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramWinget.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramChoco.ps1")

    function Invoke-WPFUIThread { }
    function Write-WinUtilLog { }
    function Start-WinUtilProcessAsStandardUser { param($FilePath, $ArgumentList) }
}

Describe "Get-WinUtilSelectedPackages" {
    BeforeEach {
        Mock Invoke-WPFUIThread { }
    }

    It "uses winget IDs when winget is preferred" {
        $packages = @(
            [pscustomobject]@{ winget = "Git.Git"; choco = "git" }
            [pscustomobject]@{ winget = "VideoLAN.VLC"; choco = "vlc" }
        )

        $result = Get-WinUtilSelectedPackages -PackageList $packages -Preference "Winget"

        (@($result["Winget"]) -join "|") | Should -Be "Git.Git|VideoLAN.VLC"
        @($result["Choco"]).Count | Should -Be 0
    }

    It "uses choco IDs and falls back to winget for na or missing choco IDs" {
        $packages = @(
            [pscustomobject]@{ winget = "Git.Git"; choco = "git" }
            [pscustomobject]@{ winget = "VideoLAN.VLC"; choco = "na" }
            [pscustomobject]@{ winget = "Mozilla.Firefox" }
        )

        $result = Get-WinUtilSelectedPackages -PackageList $packages -Preference "Choco"

        (@($result["Choco"]) -join "|") | Should -Be "git"
        (@($result["Winget"]) -join "|") | Should -Be "VideoLAN.VLC|Mozilla.Firefox"
    }

    It "skips blank, na, and missing package IDs" {
        $packages = @(
            [pscustomobject]@{ winget = ""; choco = "" }
            [pscustomobject]@{ winget = "na"; choco = "na" }
            [pscustomobject]@{ choco = "only-choco" }
            [pscustomobject]@{ winget = "   " }
        )

        $result = Get-WinUtilSelectedPackages -PackageList $packages -Preference "Winget"

        @($result["Winget"]).Count | Should -Be 0
        @($result["Choco"]).Count | Should -Be 0
    }

    It "deduplicates package IDs" {
        $packages = @(
            [pscustomobject]@{ winget = "Git.Git"; choco = "git" }
            [pscustomobject]@{ winget = "Git.Git"; choco = "git" }
            [pscustomobject]@{ winget = "VideoLAN.VLC"; choco = "vlc" }
        )

        $result = Get-WinUtilSelectedPackages -PackageList $packages -Preference "Choco"

        (@($result["Choco"]) -join "|") | Should -Be "git|vlc"
        @($result["Winget"]).Count | Should -Be 0
    }

    It "returns empty package lists for an empty selection" {
        $result = Get-WinUtilSelectedPackages -PackageList @() -Preference "Winget"

        @($result["Winget"]).Count | Should -Be 0
        @($result["Choco"]).Count | Should -Be 0
    }
}

Describe "Get-WinUtilSelectedPackages against the real Invoke-WPFUIThread" {
    # Regression guard for a real shipped bug: every other test in this file mocks
    # Invoke-WPFUIThread away, which is exactly how a regression in its actual Dispatcher.Invoke
    # cast went undetected. It was briefly changed from [action] (void) to [Func[object]] to let
    # one new caller get a Yes/No answer back - but Invoke-WPFUIThread is called as a bare,
    # uncaptured statement in dozens of places throughout the codebase, including the one
    # Get-WinUtilSelectedPackages makes near the top to update the taskbar icon. Under
    # Func[object], that bare call's result got collected into the *calling* function's own
    # output stream once gathered by ITS caller, silently turning Get-WinUtilSelectedPackages's
    # real Hashtable return value into a 2-element array (`@($null, $hashtable)`), so
    # `$result['Winget']` returned nothing. This test dot-sources and calls the real
    # Invoke-WPFUIThread (via a real WPF Dispatcher) instead of mocking it away, so that
    # particular class of regression can't hide again.
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        . (Join-Path $script:repoRoot "functions\public\Invoke-WPFUIThread.ps1")
        function Set-WinUtilTaskbaritem { param($state, $value, $overlay) }

        $script:sync = @{}
        $script:sync.form = New-Object System.Windows.Window
        $script:sync.form.Show()
        $script:sync.form.Hide()
    }

    AfterAll {
        $script:sync.form.Close()
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "returns a real Hashtable indexable by bucket name, not an array polluted by Invoke-WPFUIThread's own output" {
        $packages = @(
            [pscustomobject]@{ winget = "Docker.DockerDesktop" }
        )

        $result = Get-WinUtilSelectedPackages -PackageList $packages -Preference "Winget"

        $result | Should -BeOfType [hashtable]
        (@($result["Winget"]) -join "|") | Should -Be "Docker.DockerDesktop"
    }
}

Describe "Test-WinUtilPackageManager" {
    BeforeEach {
        Mock Write-Host { }
    }

    It "reports winget installed when the command exists" {
        Mock Get-Command {
            [pscustomobject]@{ Name = "winget" }
        } -ParameterFilter { $Name -eq "winget" -and $ErrorAction -eq "SilentlyContinue" }

        Test-WinUtilPackageManager -winget | Should -Be "installed"

        Should -Invoke -CommandName Get-Command -Times 1 -Exactly -ParameterFilter {
            $Name -eq "winget" -and $ErrorAction -eq "SilentlyContinue"
        }
    }

    It "reports choco not installed when the command is missing" {
        Mock Get-Command {
            $null
        } -ParameterFilter { $Name -eq "choco" -and $ErrorAction -eq "SilentlyContinue" }

        Test-WinUtilPackageManager -choco | Should -Be "not-installed"

        Should -Invoke -CommandName Get-Command -Times 1 -Exactly -ParameterFilter {
            $Name -eq "choco" -and $ErrorAction -eq "SilentlyContinue"
        }
    }
}

Describe "Install-WinUtilProgramWinget" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "starts winget with install arguments" {
        Install-WinUtilProgramWinget -Action Install -Programs @("Git.Git")

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "winget" -and
                (@($ArgumentList) -join "|") -eq "install|--id|Git.Git|--accept-package-agreements|--accept-source-agreements|--source|winget|--silent" -and
                $NoNewWindow -eq $true -and
                $Wait -eq $true -and
                $PassThru -eq $true
        }
    }

    It "starts winget with uninstall arguments and msstore source when requested" {
        Install-WinUtilProgramWinget -Action Uninstall -Programs @("msstore:9NBLGGH4NNS1")

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "winget" -and
                (@($ArgumentList) -join "|") -eq "uninstall|--id|9NBLGGH4NNS1|--source|msstore|--silent"
        }
    }

    It "skips whitespace and na package IDs" {
        Install-WinUtilProgramWinget -Action Install -Programs @(" ", "na")

        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "returns a success result per program when the elevated attempt succeeds" {
        $result = Install-WinUtilProgramWinget -Action Install -Programs @("Git.Git")

        $result | Should -HaveCount 1
        $result[0].Program | Should -Be "Git.Git"
        $result[0].Success | Should -BeTrue
        $result[0].ExitCode | Should -Be 0
    }

    It "retries as standard user when winget reports a wrong-integrity-context error, and succeeds if that retry works" {
        # Regression guard: uninstalling a per-user-scope package (e.g. Vivaldi) while WinUtil
        # runs elevated fails with APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED
        # (0x8A15007D / -1978335107) - that specific code should trigger exactly one de-elevated
        # retry, not be treated as a hard failure.
        Mock Start-Process { [pscustomobject]@{ ExitCode = -1978335107 } }
        Mock Start-WinUtilProcessAsStandardUser { [pscustomobject]@{ ExitCode = 0 } }

        $result = Install-WinUtilProgramWinget -Action Uninstall -Programs @("Vivaldi.Vivaldi")

        $result[0].Success | Should -BeTrue
        $result[0].ExitCode | Should -Be 0
        Should -Invoke -CommandName Start-Process -Times 1 -Exactly
        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUser -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "winget"
        }
    }

    It "does not retry on a generic failure that isn't a wrong-context error" {
        # Regression guard for the VLC case: APPINSTALLER_CLI_ERROR_EXEC_UNINSTALL_COMMAND_FAILED
        # (0x8A150030 / -1978335184) means the uninstaller itself failed (e.g. it needed admin
        # rights) - retrying de-elevated would make that worse, not better, so this must NOT
        # trigger the standard-user retry and must be reported as a real failure.
        Mock Start-Process { [pscustomobject]@{ ExitCode = -1978335184 } }
        Mock Start-WinUtilProcessAsStandardUser { [pscustomobject]@{ ExitCode = 0 } }

        $result = Install-WinUtilProgramWinget -Action Uninstall -Programs @("VideoLAN.VLC")

        $result[0].Success | Should -BeFalse
        $result[0].ExitCode | Should -Be -1978335184
        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUser -Times 0 -Exactly
    }
}

Describe "Install-WinUtilProgramChoco" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "installs packages that aren't already present" {
        function choco { param([Parameter(ValueFromRemainingArguments = $true)]$Arguments) }
        Mock choco {
            $global:LASTEXITCODE = 0
            @()
        }

        Install-WinUtilProgramChoco -Action Install -Programs @("git", "vlc")

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "choco" -and
                $ArgumentList -eq "install git vlc -y" -and
                $NoNewWindow -eq $true -and
                $Wait -eq $true -and
                $PassThru -eq $true
        }
    }

    It "upgrades packages that are already installed instead of no-op'ing via install" {
        # Regression guard: "choco install" on an already-installed package silently does
        # nothing (exit 0, no upgrade) even when a newer version is available - unlike winget,
        # which upgrades automatically. This must route already-installed IDs through
        # "choco upgrade" instead.
        function choco { param([Parameter(ValueFromRemainingArguments = $true)]$Arguments) }
        Mock choco {
            $global:LASTEXITCODE = 0
            @("git|2.43.0", "vlc|3.0.20")
        }

        Install-WinUtilProgramChoco -Action Install -Programs @("git", "vlc")

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "choco" -and $ArgumentList -eq "upgrade git vlc -y"
        }
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly -ParameterFilter {
            $FilePath -eq "choco" -and ([string]$ArgumentList).StartsWith("install")
        }
    }

    It "splits a mixed selection into an install batch and an upgrade batch" {
        function choco { param([Parameter(ValueFromRemainingArguments = $true)]$Arguments) }
        Mock choco {
            $global:LASTEXITCODE = 0
            @("git|2.43.0")
        }

        Install-WinUtilProgramChoco -Action Install -Programs @("git", "vlc")

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "choco" -and $ArgumentList -eq "install vlc -y"
        }
        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "choco" -and $ArgumentList -eq "upgrade git -y"
        }
    }

    It "falls back to installing everything when the local-package query fails" {
        function choco { param([Parameter(ValueFromRemainingArguments = $true)]$Arguments) }
        Mock choco {
            $global:LASTEXITCODE = 1
            @()
        }

        Install-WinUtilProgramChoco -Action Install -Programs @("git", "vlc")

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "choco" -and $ArgumentList -eq "install git vlc -y"
        }
    }

    It "starts choco with uninstall arguments" {
        Install-WinUtilProgramChoco -Action Uninstall -Programs @("git")

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "choco" -and $ArgumentList -eq "uninstall git -y"
        }
    }

    It "returns a per-program result reflecting the batch's actual exit code" {
        function choco { param([Parameter(ValueFromRemainingArguments = $true)]$Arguments) }
        Mock choco {
            $global:LASTEXITCODE = 0
            @("git|2.43.0")
        }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } } -ParameterFilter { $ArgumentList -eq "upgrade git -y" }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $ArgumentList -eq "install vlc -y" }

        $result = Install-WinUtilProgramChoco -Action Install -Programs @("git", "vlc")

        (@($result) | Where-Object { $_.Program -eq "git" }).Success | Should -BeFalse
        (@($result) | Where-Object { $_.Program -eq "vlc" }).Success | Should -BeTrue
    }

    It "returns a failure result on uninstall when choco reports a non-zero exit code" {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } }

        $result = Install-WinUtilProgramChoco -Action Uninstall -Programs @("git")

        $result[0].Program | Should -Be "git"
        $result[0].Success | Should -BeFalse
        $result[0].ExitCode | Should -Be 1
    }
}
