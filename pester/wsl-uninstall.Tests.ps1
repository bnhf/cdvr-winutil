#===========================================================================
# Tests - WSL2 / WSL distro uninstall
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilWSLDistro.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilFeatureWSL.ps1")

    function wsl {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }
    function Write-WinUtilLog {
        param($Message, $Level, $Component)
    }
    function Test-WinUtilWSLDistroInstalled { param($Distro) $true }
}

Describe "Uninstall-WinUtilWSLDistro" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock wsl { $global:LASTEXITCODE = 0 }
    }

    It "terminates and unregisters a distro that is currently registered" {
        Mock Test-WinUtilWSLDistroInstalled { $true }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        Uninstall-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--terminate Debian" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--unregister Debian" }
    }

    It "does nothing for a distro that isn't registered" {
        # Regression guard: unregistering permanently deletes the distro's filesystem - must
        # not attempt it against a distro that was never installed in the first place.
        Mock Test-WinUtilWSLDistroInstalled { $false }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        Uninstall-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly
    }

    It "logs an error and skips a package missing a distro name" {
        $package = [pscustomobject]@{ content = "Bad Entry"; distro = "" }
        Uninstall-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "ERROR" }
    }
}

Describe "Uninstall-WinUtilFeatureWSL" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = [pscustomobject]@{
                applicationsHashtable = @{
                    WPFInstallwsl2 = [pscustomobject]@{ content = "WSL2"; installType = "wslFeature" }
                    WPFInstalldebian = [pscustomobject]@{ content = "Debian (WSL)"; installType = "wslDistro"; distro = "Debian" }
                    WPFInstallchrome = [pscustomobject]@{ content = "Chrome"; winget = "Google.Chrome.EXE" }
                }
            }
        })
        Mock Write-WinUtilLog { }
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Test-WinUtilWSLDistroInstalled { $true }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "unregisters only the catalog's own WSL distro(s), then shuts down and uninstalls the WSL runtime" {
        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--unregister Debian" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--shutdown" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--uninstall" }
    }

    It "never touches an application entry that isn't a catalog WSL distro, even from the same hashtable" {
        # Regression guard: only installType "wslDistro" entries get unregistered here - an
        # unrelated catalog entry (Chrome) sitting in the same applicationsHashtable must never
        # be passed to wsl.exe.
        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly -ParameterFilter { ($Arguments -join " ") -like "*Chrome*" }
    }

    It "does not unregister a distro if none are declared in the catalog" {
        $script:sync.configs.applicationsHashtable.Remove("WPFInstalldebian")

        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly -ParameterFilter { ($Arguments -join " ") -like "*unregister*" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--uninstall" }
    }
}
