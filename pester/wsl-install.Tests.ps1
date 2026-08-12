#===========================================================================
# Tests - WSL2 / WSL distro / WSL command install
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilWithTimeout.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilFeatureWSL.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilWSLDistro.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilWSLCommand.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilDockerAvailableInWSL.ps1")

    function wsl {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }
    function Write-WinUtilLog {
        param($Message, $Level, $Component)
    }
    function Test-WinUtilWSLFeatureEnabled { $true }
    function Test-WinUtilWSLDistroInstalled { param($Distro) $true }
    function Set-WinUtilNoBomFileContent { param($Path, $Value) }
    function Set-WinUtilTweaksProgressIndicator { param($Visible, $Label, $Percent) }
    function Get-WinUtilLanIPAddress { "192.168.1.50" }
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
        Mock Set-WinUtilNoBomFileContent { }
        Mock Remove-Item { }
        Mock Get-WinUtilLanIPAddress { "192.168.1.50" }
    }

    It "substitutes {{LAN_IP}} with the detected LAN address" {
        # This is what CHANNELS_DVR in Olivetin's command now uses instead of a hardcoded
        # "host.docker.internal" - see Get-WinUtilLanIPAddress.ps1 for why.
        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "docker run -e CHANNELS_DVR={{LAN_IP}}:8089 image" }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Set-WinUtilNoBomFileContent -Times 1 -Exactly -ParameterFilter {
            $Value -eq "docker run -e CHANNELS_DVR=192.168.1.50:8089 image"
        }
    }

    It "falls back to host.docker.internal for {{LAN_IP}} when it can't be determined" {
        Mock Get-WinUtilLanIPAddress { $null }

        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "docker run -e CHANNELS_DVR={{LAN_IP}}:8089 image" }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Set-WinUtilNoBomFileContent -Times 1 -Exactly -ParameterFilter {
            $Value -eq "docker run -e CHANNELS_DVR=host.docker.internal:8089 image"
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "Could not determine a LAN IP address*"
        }
    }

    It "runs the command and logs completion on success" {
        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "echo hi" }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Olivetin install completed." }
    }

    It "writes the script without a BOM, via Set-WinUtilNoBomFileContent rather than Set-Content" {
        # Regression guard for a real production bug: Set-Content -Encoding UTF8 prepends a
        # byte-order-mark under Windows PowerShell 5.1 (confirmed live), which bash doesn't
        # strip, corrupting the first word of the script - "docker: command not found" was
        # actually a mangled "<BOM>docker".
        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "docker run hello" }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Set-WinUtilNoBomFileContent -Times 1 -Exactly -ParameterFilter {
            $Value -eq "docker run hello"
        }
    }

    It "reports failure, not completion, when the command exits non-zero" {
        # Regression guard for a real production bug: a failed docker command (exit 127,
        # "command not found") was still logged as "install completed" - only the ABSENCE of
        # output was treated as a failure before, not a non-zero exit code.
        Mock wsl { $global:LASTEXITCODE = 127; "docker: command not found" }

        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "docker run hello" }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter { $Message -eq "Olivetin install completed." }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Message -like "Olivetin install FAILED (exit code: 127)*"
        }
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

    It "checks docker availability first when requiresDockerInDistro is set, and skips the install if it's not available" {
        # Regression guard for the actual reported bug: Docker Desktop installed but WSL
        # integration not enabled for Debian - running the install anyway just fails deep inside
        # the script with a generic "command not found" that doesn't point at the real cause.
        Mock Test-WinUtilDockerAvailableInWSL { [pscustomobject]@{ Available = $false; Reason = "docker not reachable - enable WSL integration" } }

        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "docker run hello"; requiresDockerInDistro = $true }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Test-WinUtilDockerAvailableInWSL -Times 1 -Exactly -ParameterFilter { $Distro -eq "Debian" }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Message -eq "Skipping Olivetin install - docker not reachable - enable WSL integration"
        }
        Should -Invoke -CommandName wsl -Times 0 -Exactly
        Should -Invoke -CommandName Set-WinUtilNoBomFileContent -Times 0 -Exactly
    }

    It "proceeds normally when requiresDockerInDistro is set and docker is available" {
        Mock Test-WinUtilDockerAvailableInWSL { [pscustomobject]@{ Available = $true; Reason = $null } }

        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; command = "docker run hello"; requiresDockerInDistro = $true }
        Install-WinUtilWSLCommand -Action Install -Packages @($package)

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Olivetin install completed." }
    }

    It "does not check docker availability for Uninstall, even when requiresDockerInDistro is set" {
        # If docker was reachable when this installed, gating the cleanup step on it too would
        # only ever block the user from removing something, for no benefit.
        Mock Test-WinUtilDockerAvailableInWSL { [pscustomobject]@{ Available = $false; Reason = "n/a" } }

        $package = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; distro = "Debian"; uninstallCommand = "docker rm -f olivetin"; requiresDockerInDistro = $true }
        Install-WinUtilWSLCommand -Action Uninstall -Packages @($package)

        Should -Invoke -CommandName Test-WinUtilDockerAvailableInWSL -Times 0 -Exactly
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -eq "Olivetin uninstall completed." }
    }
}

Describe "Test-WinUtilDockerAvailableInWSL" {
    BeforeEach {
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock @ArgumentList }
    }

    It "reports available when the docker CLI is present and the daemon is reachable" {
        $result = Test-WinUtilDockerAvailableInWSL -Distro "Debian"

        $result.Available | Should -BeTrue
        $result.Reason | Should -BeNullOrEmpty
    }

    It "reports a specific reason when the docker CLI isn't present" {
        # This is the actual reported scenario: Docker Desktop installed, but WSL integration
        # not enabled for the target distro, so "docker" doesn't exist there at all.
        Mock wsl { $global:LASTEXITCODE = 127 } -ParameterFilter { ($Arguments -join " ") -like "*command -v docker*" }

        $result = Test-WinUtilDockerAvailableInWSL -Distro "Debian"

        $result.Available | Should -BeFalse
        $result.Reason | Should -BeLike "*isn't available inside the Debian*"
        $result.Reason | Should -BeLike "*WSL Integration*"
    }

    It "reports a different, specific reason when the CLI exists but the daemon isn't reachable" {
        Mock wsl { $global:LASTEXITCODE = 0 } -ParameterFilter { ($Arguments -join " ") -like "*command -v docker*" }
        Mock wsl { $global:LASTEXITCODE = 1 } -ParameterFilter { ($Arguments -join " ") -like "*docker info*" }

        $result = Test-WinUtilDockerAvailableInWSL -Distro "Debian"

        $result.Available | Should -BeFalse
        $result.Reason | Should -BeLike "*can't reach the Docker daemon*"
    }
}
