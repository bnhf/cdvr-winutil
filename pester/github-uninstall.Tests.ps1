#===========================================================================
# Tests - GitHub-install-type uninstall via the registered Windows uninstaller
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilProgramUninstallString.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilProgramGithub.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }
    function Set-WinUtilProcessForeground { param($Process) }
    function Start-WinUtilProcessAsStandardUserNoWait { param($FilePath, $ArgumentList) }
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
}
