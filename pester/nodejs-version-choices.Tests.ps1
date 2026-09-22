#===========================================================================
# Tests - Get-WinUtilNodeJsVersionChoices
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilNodeJsVersionChoices.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }
}

Describe "Get-WinUtilNodeJsVersionChoices" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        # The function caches a successful fetch in this $script: variable (scoped to this test
        # file, since that's where it was dot-sourced) - cleared before every test so results
        # from one test can't leak into the next via the cache.
        Remove-Variable -Name WinUtilNodeJsVersionChoicesCache -Scope Script -ErrorAction SilentlyContinue
    }

    It "always defaults to 24.13.0" {
        Mock Invoke-RestMethod { throw "offline" }

        $result = Get-WinUtilNodeJsVersionChoices

        $result.Default | Should -Be "24.13.0"
    }

    It "falls back to a single default-only choice when nodejs.org can't be reached" {
        Mock Invoke-RestMethod { throw "offline" }

        $result = Get-WinUtilNodeJsVersionChoices

        @($result.Choices).Count | Should -Be 1
        $result.Choices[0].Value | Should -Be "24.13.0"
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" }
    }

    It "returns only the latest release of each of the 5 most recent major versions" {
        Mock Invoke-RestMethod {
            @(
                [pscustomobject]@{ version = "v25.1.0"; lts = $false }
                [pscustomobject]@{ version = "v24.13.0"; lts = "Krypton" }
                [pscustomobject]@{ version = "v24.12.0"; lts = "Krypton" }
                [pscustomobject]@{ version = "v23.5.0"; lts = $false }
                [pscustomobject]@{ version = "v22.11.0"; lts = "Jod" }
                [pscustomobject]@{ version = "v22.10.0"; lts = "Jod" }
                [pscustomobject]@{ version = "v21.7.0"; lts = $false }
                [pscustomobject]@{ version = "v20.18.0"; lts = "Iron" }
                [pscustomobject]@{ version = "v18.20.0"; lts = "Hydrogen" }
            )
        }

        $result = Get-WinUtilNodeJsVersionChoices

        $values = $result.Choices | ForEach-Object { $_.Value }
        $values | Should -Be @("25.1.0", "24.13.0", "23.5.0", "22.11.0", "21.7.0")
        ($result.Choices | Where-Object { $_.Value -eq "25.1.0" }).Label | Should -Be "25.1.0 (Current)"
        ($result.Choices | Where-Object { $_.Value -eq "22.11.0" }).Label | Should -Be "22.11.0 (LTS: Jod)"
        $values | Should -Not -Contain "20.18.0"
    }

    It "doesn't duplicate 24.13.0 when it's already among the 5 most recent majors" {
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ version = "v24.13.0"; lts = "Krypton" }, [pscustomobject]@{ version = "v22.11.0"; lts = "Jod" })
        }

        $result = Get-WinUtilNodeJsVersionChoices

        @($result.Choices | Where-Object { $_.Value -eq "24.13.0" }).Count | Should -Be 1
    }

    It "adds 24.13.0 as an extra choice when it falls outside the 5 most recent majors" {
        Mock Invoke-RestMethod {
            @(
                [pscustomobject]@{ version = "v30.0.0"; lts = $false }
                [pscustomobject]@{ version = "v29.0.0"; lts = "Lithium" }
                [pscustomobject]@{ version = "v28.0.0"; lts = $false }
                [pscustomobject]@{ version = "v27.0.0"; lts = "Helium" }
                [pscustomobject]@{ version = "v26.0.0"; lts = $false }
                [pscustomobject]@{ version = "v22.11.0"; lts = "Jod" }
            )
        }

        $result = Get-WinUtilNodeJsVersionChoices

        @($result.Choices).Count | Should -Be 6
        $result.Choices | Where-Object { $_.Value -eq "24.13.0" } | Should -Not -BeNullOrEmpty
    }

    It "caches a successful fetch so a second call doesn't hit the network again" {
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ version = "v24.13.0"; lts = "Krypton" })
        }

        Get-WinUtilNodeJsVersionChoices | Out-Null
        Get-WinUtilNodeJsVersionChoices | Out-Null

        Should -Invoke -CommandName Invoke-RestMethod -Times 1 -Exactly
    }

    It "does not cache a failed fetch, so a later call retries the network" {
        Mock Invoke-RestMethod { throw "offline" }

        Get-WinUtilNodeJsVersionChoices | Out-Null
        Get-WinUtilNodeJsVersionChoices | Out-Null

        Should -Invoke -CommandName Invoke-RestMethod -Times 2 -Exactly
    }
}
