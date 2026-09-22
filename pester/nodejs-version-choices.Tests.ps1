#===========================================================================
# Tests - Get-WinUtilNodeJsVersionChoices
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilNodeJsVersionChoices.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }
    function winget {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }

    # winget's real CLI output for "show --id OpenJS.NodeJS --versions": header/separator lines
    # plus one bare "N.N.N" version per line, newest first. Confirmed live - this is the actual
    # shape that broke the earlier nodejs.org-sourced version, since 24.11.0-24.13.0 simply
    # don't appear here even though nodejs.org itself published them.
    function script:New-WinUtilWingetVersionOutput {
        param([string[]]$Versions)
        @("Found Node.js [OpenJS.NodeJS]", "Version", "-------") + $Versions
    }
}

Describe "Get-WinUtilNodeJsVersionChoices" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        # The function caches a successful fetch in this $script: variable (scoped to this test
        # file, since that's where it was dot-sourced) - cleared before every test so results
        # from one test can't leak into the next via the cache.
        Remove-Variable -Name WinUtilNodeJsVersionChoicesCache -Scope Script -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }

    It "returns only the latest release of each of the 5 most recent major versions" {
        Mock winget {
            $global:LASTEXITCODE = 0
            New-WinUtilWingetVersionOutput -Versions @(
                "26.7.0", "26.6.0",
                "25.9.0", "25.8.2",
                "24.10.0", "24.9.0",
                "23.5.0",
                "22.11.0", "22.10.0",
                "20.18.0"
            )
        }

        $result = Get-WinUtilNodeJsVersionChoices

        $values = $result.Choices | ForEach-Object { $_.Value }
        $values | Should -Be @("26.7.0", "25.9.0", "24.10.0", "23.5.0", "22.11.0")
        $values | Should -Not -Contain "20.18.0"
    }

    It "regression guard: never offers a version winget's own catalog doesn't have (e.g. 24.13.0)" {
        # Confirmed live: winget-pkgs' OpenJS.NodeJS manifests jump straight from 24.10.0 to
        # 25.0.0 - 24.11.0 through 24.13.0 don't exist there even though nodejs.org published
        # them, so a version picked from nodejs.org's own release index (the earlier
        # implementation's source) could be entirely uninstallable via winget's own
        # "--version X --exact", failing with "No version found matching: X". This test's mock
        # output is exactly that real gap.
        Mock winget {
            $global:LASTEXITCODE = 0
            New-WinUtilWingetVersionOutput -Versions @("25.0.0", "24.10.0", "24.9.0")
        }

        $result = Get-WinUtilNodeJsVersionChoices

        $result.Choices | Where-Object { $_.Value -eq "24.13.0" } | Should -BeNullOrEmpty
        $result.Default | Should -Not -Be "24.13.0"
    }

    It "defaults to the newest available version" {
        Mock winget {
            $global:LASTEXITCODE = 0
            New-WinUtilWingetVersionOutput -Versions @("26.7.0", "24.10.0")
        }

        $result = Get-WinUtilNodeJsVersionChoices

        $result.Default | Should -Be "26.7.0"
    }

    It "falls back to a single unpinned choice (empty Value) when winget can't be queried" {
        Mock winget { $global:LASTEXITCODE = 1; "" }

        $result = Get-WinUtilNodeJsVersionChoices

        @($result.Choices).Count | Should -Be 1
        $result.Choices[0].Value | Should -Be ""
        $result.Default | Should -Be ""
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" }
    }

    It "falls back to a single unpinned choice when winget's output has no parseable version lines" {
        Mock winget { $global:LASTEXITCODE = 0; "Found Node.js [OpenJS.NodeJS]" }

        $result = Get-WinUtilNodeJsVersionChoices

        @($result.Choices).Count | Should -Be 1
        $result.Choices[0].Value | Should -Be ""
    }

    It "caches a successful fetch so a second call doesn't query winget again" {
        Mock winget {
            $global:LASTEXITCODE = 0
            New-WinUtilWingetVersionOutput -Versions @("24.10.0")
        }

        Get-WinUtilNodeJsVersionChoices | Out-Null
        Get-WinUtilNodeJsVersionChoices | Out-Null

        Should -Invoke -CommandName winget -Times 1 -Exactly
    }

    It "does not cache a failed fetch, so a later call retries winget" {
        Mock winget { $global:LASTEXITCODE = 1; "" }

        Get-WinUtilNodeJsVersionChoices | Out-Null
        Get-WinUtilNodeJsVersionChoices | Out-Null

        Should -Invoke -CommandName winget -Times 2 -Exactly
    }
}
