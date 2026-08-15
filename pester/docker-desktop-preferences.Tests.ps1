#===========================================================================
# Tests - Set-WinUtilDockerDesktopPreferences
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Set-WinUtilDockerDesktopPreferences.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }

    $script:settingsPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
    $script:legacySettingsPath = Join-Path $env:APPDATA 'Docker\settings.json'
    $script:dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
}

Describe "Set-WinUtilDockerDesktopPreferences" {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Write-WinUtilLog { }
        # A real Get-Process return with nothing found is $null (no pipeline output at all), which
        # would make a downstream Stop-Process mock look like it was never invoked regardless of
        # whether the code actually piped into it - returning a fake match here instead so that
        # distinction is testable.
        Mock Get-Process { [pscustomobject]@{ Id = 1234; Name = "Docker Desktop" } }
        Mock Stop-Process { }
        Mock Start-Process { }
        $script:capturedContent = $null
        Mock Set-Content {
            $script:capturedContent = $Value
        }
    }

    It "warns and does nothing further when the settings file never appears within the timeout" {
        Mock Test-Path { $false }

        Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe -TimeoutSeconds 0

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" }
        Should -Invoke -CommandName Stop-Process -Times 0 -Exactly
        Should -Invoke -CommandName Set-Content -Times 0 -Exactly
    }

    It "does not relaunch Docker Desktop when the settings file never appeared" {
        # There is nothing to have closed, and no changed preferences to relaunch for - the
        # caller already launched it once themselves.
        Mock Test-Path { $false }

        Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe -TimeoutSeconds 0

        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    Context "when the settings file exists" {
        BeforeEach {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $script:settingsPath }
            Mock Test-Path { $false } -ParameterFilter { $Path -eq $script:legacySettingsPath }
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $script:dockerExe }
            Mock Get-Content { '{"existingKey":"keepme"}' }
        }

        It "stops Docker Desktop before editing the settings file" {
            Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe

            Should -Invoke -CommandName Get-Process -Times 1 -Exactly -ParameterFilter { $Name -eq "Docker Desktop" }
            Should -Invoke -CommandName Stop-Process -Times 1 -Exactly
        }

        It "writes the requested autoStart, inverted openUIOnStartupDisabled, and WSL integration values" {
            Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe -StartAtLogin $true -OpenDashboardOnStartup $false -EnableDefaultWslIntegration $true

            $written = $script:capturedContent | ConvertFrom-Json
            $written.autoStart | Should -Be $true
            $written.openUIOnStartupDisabled | Should -Be $true
            $written.enableIntegrationWithDefaultWslDistro | Should -Be $true
        }

        It "inverts openUIOnStartupDisabled correctly when OpenDashboardOnStartup is requested on" {
            Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe -OpenDashboardOnStartup $true

            $written = $script:capturedContent | ConvertFrom-Json
            $written.openUIOnStartupDisabled | Should -Be $false
        }

        It "preserves other existing keys already in the settings file" {
            Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe

            $written = $script:capturedContent | ConvertFrom-Json
            $written.existingKey | Should -Be "keepme"
        }

        It "relaunches Docker Desktop after successfully updating the settings" {
            Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe

            Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq $script:dockerExe }
        }

        It "logs an error but still relaunches Docker Desktop when the settings file is malformed" {
            Mock Get-Content { "not valid json{{{" }

            { Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe } | Should -Not -Throw

            Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "ERROR" }
            Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq $script:dockerExe }
        }
    }

    Context "falling back to the legacy settings.json" {
        It "uses settings.json when settings-store.json doesn't exist" {
            Mock Test-Path { $false } -ParameterFilter { $Path -eq $script:settingsPath }
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $script:legacySettingsPath }
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $script:dockerExe }
            Mock Get-Content { '{}' }

            Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe

            Should -Invoke -CommandName Get-Content -Times 1 -Exactly -ParameterFilter { $Path -eq $script:legacySettingsPath }
        }

        It "prefers settings-store.json when both exist" {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $script:settingsPath }
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $script:legacySettingsPath }
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $script:dockerExe }
            Mock Get-Content { '{}' }

            Set-WinUtilDockerDesktopPreferences -DockerExePath $script:dockerExe

            Should -Invoke -CommandName Get-Content -Times 1 -Exactly -ParameterFilter { $Path -eq $script:settingsPath }
        }
    }
}
