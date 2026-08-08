#===========================================================================
# Tests - WSL2 / WSL distro / WSL command install
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilWithTimeout.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilFeatureWSL.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilWSLDistro.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilWSLCommand.ps1")

    function wsl {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }
    function Write-WinUtilLog {
        param($Message, $Level, $Component)
    }
    function Test-WinUtilWSLFeatureEnabled { $true }
    function Test-WinUtilWSLDistroInstalled { param($Distro) $true }
}

Describe "Install-WinUtilFeatureWSL" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{ WSLRuntimeUninstalled = $true })
        Mock Write-WinUtilLog { }
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock @ArgumentList }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "enables WSL2, clears the uninstalled-this-session flag, and reports success when confirmed usable" {
        Mock Test-WinUtilWSLFeatureEnabled { $true }

        Install-WinUtilFeatureWSL -Packages @([pscustomobject]@{ content = "WSL2" })

        $script:sync.WSLRuntimeUninstalled | Should -BeFalse
        Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter { $Level -eq "ERROR" }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -eq "WSL2: WSL2 is enabled and usable." }
    }

    It "warns instead of failing outright when wsl --install times out, then still checks real status" {
        # Regression guard for a real production hang: "wsl --install" (like "wsl --install -d
        # <distro>", see Install-WinUtilWSLDistro.ps1) can hang well beyond a normal install -
        # a timeout here must not be treated as a hard failure, since the underlying work may
        # have already succeeded.
        Mock Invoke-WinUtilWithTimeout { $null }
        Mock Test-WinUtilWSLFeatureEnabled { $true }

        Install-WinUtilFeatureWSL -Packages @([pscustomobject]@{ content = "WSL2" })

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "wsl --install --no-distribution did not finish*"
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -eq "WSL2: WSL2 is enabled and usable." }
    }

    It "warns that a restart is likely needed when WSL2 doesn't yet appear usable" {
        Mock Test-WinUtilWSLFeatureEnabled { $false }

        Install-WinUtilFeatureWSL -Packages @([pscustomobject]@{ content = "WSL2" })

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "*restart is likely required*"
        }
    }
}

Describe "Install-WinUtilWSLDistro" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock @ArgumentList }
    }

    It "installs a distro and reports success when it's confirmed registered afterward" {
        Mock Test-WinUtilWSLDistroInstalled { $true }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        Install-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter { $Level -eq "ERROR" }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -like "Debian (WSL) (Debian) is installed and registered*" }
    }

    It "reports success on a timeout when the distro is confirmed registered anyway" {
        # Regression guard for the exact reported bug: "wsl --install -d Debian" never returned
        # control (it auto-launches the distro for first-run username/password setup, which
        # hangs with no console attached), but "wsl --list" showed Debian was already fully
        # registered. A timeout here must not be reported as a failure once independently
        # verified as actually successful.
        Mock Invoke-WinUtilWithTimeout { $null }
        Mock Test-WinUtilWSLDistroInstalled { $true }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        Install-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "wsl --install -d Debian did not finish*"
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter { $Level -eq "ERROR" }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -like "*is installed and registered*" }
    }

    It "reports an error when the distro is not registered after the install attempt" {
        Mock Test-WinUtilWSLDistroInstalled { $false }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        Install-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Message -like "*does not appear to be registered*"
        }
    }

    It "logs an error and skips a package missing a distro name" {
        $package = [pscustomobject]@{ content = "Bad Entry"; distro = "" }
        Install-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "ERROR" }
    }
}

Describe "Install-WinUtilWSLCommand" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock @ArgumentList }
        Mock Set-Content { }
        Mock Remove-Item { }
    }

    It "runs the command and logs completion on success" {
        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "echo hi" }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Olivetin install completed." }
    }

    It "warns instead of failing outright when the command times out" {
        # No independent way to verify an arbitrary command's success after a timeout (unlike
        # the distro/feature installers above), so this can only warn, not confirm either way.
        Mock Invoke-WinUtilWithTimeout { $null }

        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "echo hi" }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "Olivetin install did not finish*"
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter { $Message -eq "Olivetin install completed." }
    }
}
