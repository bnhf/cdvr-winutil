#===========================================================================
# Tests - Direct/GitHub install de-elevation (Channels DVR must not run as admin)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramDirect.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilProgramDirect.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramGithub.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec) }
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) }
    function Set-WinUtilProcessForeground { param($Process) }
    function Start-WinUtilProcessAsStandardUser { param($FilePath, $ArgumentList) }
    function Start-WinUtilProcessAsStandardUserNoWait { param($FilePath, $ArgumentList) }

    function script:New-WinUtilDirectPackage {
        param(
            [string]$Name = "Channels DVR",
            [string]$Url = "https://example.com/SetupChannelsDVR.exe",
            [string]$InstallArgs = "",
            [string]$UninstallCommand,
            [bool]$UninstallViaInstaller = $false
        )

        [pscustomobject]@{
            content              = $Name
            url                  = $Url
            args                 = $InstallArgs
            uninstallCommand     = $UninstallCommand
            uninstallViaInstaller = $UninstallViaInstaller
        }
    }
}

Describe "Start-WinUtilProcessAsStandardUserNoWait" {
    BeforeAll {
        . (Join-Path $script:repoRoot "functions\private\Start-WinUtilProcessAsStandardUserNoWait.ps1")
    }

    BeforeEach {
        # New-ScheduledTask*/-Action etc. just build in-memory CIM objects with no system
        # effect, so they run for real - Pester's mock proxies still enforce the original
        # cmdlets' strongly-typed parameters (e.g. -Action wants an MSFT_TaskAction CimInstance),
        # so a plain mocked return value fails type binding at the next cmdlet in the chain.
        # Only the cmdlets that actually touch the system are mocked.
        Mock Write-WinUtilLog { }
        Mock Import-Module { }
        Mock Register-ScheduledTask { }
        Mock Start-ScheduledTask { }
        Mock Start-Sleep { }
        Mock Get-ScheduledTask { $null }
        Mock Unregister-ScheduledTask { }
    }

    It "registers a Limited run-level task, starts it, and returns true on success" {
        $result = Start-WinUtilProcessAsStandardUserNoWait -FilePath "C:\temp\SetupChannelsDVR.exe"

        $result | Should -BeTrue
        Should -Invoke -CommandName Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $InputObject.Principal.RunLevel -eq "Limited"
        }
        Should -Invoke -CommandName Start-ScheduledTask -Times 1 -Exactly
    }

    It "unregisters the task after starting it, not the spawned process" {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = "whatever" } }

        Start-WinUtilProcessAsStandardUserNoWait -FilePath "C:\temp\SetupChannelsDVR.exe" | Out-Null

        Should -Invoke -CommandName Unregister-ScheduledTask -Times 1 -Exactly
    }

    It "returns false and logs a warning when task registration fails" {
        Mock Register-ScheduledTask { throw "access denied" }

        $result = Start-WinUtilProcessAsStandardUserNoWait -FilePath "C:\temp\SetupChannelsDVR.exe"

        $result | Should -BeFalse
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" }
    }
}

Describe "Install-WinUtilProgramDirect" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Invoke-WebRequest { }
        Mock Set-WinUtilProcessForeground { }
        Mock Start-WinUtilProcessAsStandardUserNoWait { $true }
        Mock Start-WinUtilProcessAsStandardUser { [pscustomobject]@{ ExitCode = 0 } }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "launches a no-args interactive installer de-elevated, not via Start-Process directly" {
        # Regression guard: Channels DVR Server's installer (args: "") used to launch via plain
        # Start-Process, inheriting WinUtil's own elevated token - so the DVR server ended up
        # installed and running as Administrator.
        $package = New-WinUtilDirectPackage

        Install-WinUtilProgramDirect -Packages @($package)

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly -ParameterFilter {
            $FilePath -like "*Channels DVR.exe"
        }
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "falls back to an elevated launch (with foreground) when de-elevation fails" {
        Mock Start-WinUtilProcessAsStandardUserNoWait { $false }

        Install-WinUtilProgramDirect -Packages @(New-WinUtilDirectPackage)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter { $PassThru -eq $true }
        Should -Invoke -CommandName Set-WinUtilProcessForeground -Times 1 -Exactly
    }

    It "installs an MSI de-elevated via the waiting helper" {
        $package = New-WinUtilDirectPackage -Url "https://example.com/App.msi"

        Install-WinUtilProgramDirect -Packages @($package)

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUser -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "msiexec.exe"
        }
    }

    It "installs with explicit silent args de-elevated via the waiting helper" {
        $package = New-WinUtilDirectPackage -InstallArgs "/S"

        Install-WinUtilProgramDirect -Packages @($package)

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUser -Times 1 -Exactly -ParameterFilter {
            $FilePath -like "*Channels DVR.exe"
        }
    }
}

Describe "Uninstall-WinUtilProgramDirect" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Invoke-WebRequest { }
        Mock Set-WinUtilProcessForeground { }
        Mock Start-WinUtilProcessAsStandardUserNoWait { $true }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "relaunches the installer de-elevated for uninstallViaInstaller packages" {
        $package = New-WinUtilDirectPackage -UninstallViaInstaller $true

        Uninstall-WinUtilProgramDirect -Packages @($package)

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly -ParameterFilter {
            $FilePath -like "*Channels DVR-uninstall.exe"
        }
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "falls back to an elevated relaunch when de-elevation fails" {
        Mock Start-WinUtilProcessAsStandardUserNoWait { $false }

        Uninstall-WinUtilProgramDirect -Packages @(New-WinUtilDirectPackage -UninstallViaInstaller $true)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly
        Should -Invoke -CommandName Set-WinUtilProcessForeground -Times 1 -Exactly
    }
}

Describe "Install-WinUtilProgramGithub" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                assets = @([pscustomobject]@{ name = "Clicker-Setup-1.0.0.exe"; browser_download_url = "https://example.com/Clicker-Setup-1.0.0.exe" })
            }
        }
        Mock Invoke-WebRequest { }
        Mock Set-WinUtilProcessForeground { }
        Mock Start-WinUtilProcessAsStandardUserNoWait { $true }
        Mock Start-WinUtilProcessAsStandardUser { [pscustomobject]@{ ExitCode = 0 } }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "launches the downloaded release asset de-elevated" {
        $package = [pscustomobject]@{ content = "Clicker"; repo = "mackid1993/Clicker"; assetPattern = "Clicker-Setup-*.exe" }

        Install-WinUtilProgramGithub -Packages @($package)

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }
}
