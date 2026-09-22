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

    It "returns the latest Current release plus the latest release of each active LTS major" {
        Mock Invoke-RestMethod {
            @(
                [pscustomobject]@{ version = "v25.1.0"; lts = $false }
                [pscustomobject]@{ version = "v24.13.0"; lts = "Krypton" }
                [pscustomobject]@{ version = "v24.12.0"; lts = "Krypton" }
                [pscustomobject]@{ version = "v22.11.0"; lts = "Jod" }
                [pscustomobject]@{ version = "v22.10.0"; lts = "Jod" }
                [pscustomobject]@{ version = "v20.18.0"; lts = "Iron" }
            )
        }

        $result = Get-WinUtilNodeJsVersionChoices

        $values = $result.Choices | ForEach-Object { $_.Value }
        $values | Should -Be @("25.1.0", "24.13.0", "22.11.0", "20.18.0")
        ($result.Choices | Where-Object { $_.Value -eq "25.1.0" }).Label | Should -Be "25.1.0 (Current)"
        ($result.Choices | Where-Object { $_.Value -eq "22.11.0" }).Label | Should -Be "22.11.0 (LTS: Jod)"
    }

    It "doesn't duplicate 24.13.0 when the live index already includes it" {
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ version = "v24.13.0"; lts = "Krypton" })
        }

        $result = Get-WinUtilNodeJsVersionChoices

        @($result.Choices | Where-Object { $_.Value -eq "24.13.0" }).Count | Should -Be 1
    }

    It "adds 24.13.0 as a choice when the live index doesn't include it" {
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ version = "v22.11.0"; lts = "Jod" })
        }

        $result = Get-WinUtilNodeJsVersionChoices

        $result.Choices | Where-Object { $_.Value -eq "24.13.0" } | Should -Not -BeNullOrEmpty
    }
}
