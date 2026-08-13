#===========================================================================
# Tests - Direct/GitHub install de-elevation (Channels DVR must not run as admin)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramDirect.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilProgramDirect.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramGithub.ps1")
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPortableGithubInstallDir.ps1")
    . (Join-Path $script:repoRoot "functions\private\Stop-WinUtilProcessByAssetPattern.ps1")

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

    It "reports download and install milestones via ProgressCallback" {
        $messages = [System.Collections.Generic.List[string]]::new()

        Install-WinUtilProgramDirect -Packages @(New-WinUtilDirectPackage) -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @("Downloading Channels DVR...", "Installing Channels DVR...")
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

    It "reports the uninstall milestone via ProgressCallback" {
        $messages = [System.Collections.Generic.List[string]]::new()

        Uninstall-WinUtilProgramDirect -Packages @(New-WinUtilDirectPackage -UninstallCommand "Write-Output 'noop'") -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @("Uninstalling Channels DVR...")
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
        Mock New-Item { }
        Mock Move-Item { }
        Mock Stop-WinUtilProcessByAssetPattern { }
        Mock Start-Sleep { }
    }

    It "launches the downloaded release asset de-elevated" {
        $package = [pscustomobject]@{ content = "Clicker"; repo = "mackid1993/Clicker"; assetPattern = "Clicker-Setup-*.exe" }

        Install-WinUtilProgramGithub -Packages @($package)

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "reports release-check, download, and install milestones via ProgressCallback" {
        $package = [pscustomobject]@{ content = "Clicker"; repo = "mackid1993/Clicker"; assetPattern = "Clicker-Setup-*.exe" }
        $messages = [System.Collections.Generic.List[string]]::new()

        Install-WinUtilProgramGithub -Packages @($package) -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @("Checking latest release for Clicker...", "Downloading Clicker...", "Installing Clicker...")
    }

    It "runs postInstallCommand after the no-args interactive install branch" {
        # Regression guard: Clicker's Rust/WinUI3 executable needs the VC++ Redistributable to
        # run at all ("VCRUNTIME140.dll was not found" otherwise) - this is how it gets pulled
        # in silently as part of installing Clicker, rather than as a separate visible catalog
        # entry. The interactive branch's launch is fire-and-forget with no success signal to
        # gate on, so this must run regardless, not just when something reports success.
        Remove-Variable -Name postInstallRan -Scope Script -ErrorAction SilentlyContinue
        $package = [pscustomobject]@{
            content = "Clicker"; repo = "mackid1993/Clicker"; assetPattern = "Clicker-Setup-*.exe"
            postInstallCommand = 'Set-Variable -Name postInstallRan -Value $true -Scope Script'
        }

        Install-WinUtilProgramGithub -Packages @($package)

        $script:postInstallRan | Should -BeTrue
        Remove-Variable -Name postInstallRan -Scope Script -ErrorAction SilentlyContinue
    }

    It "runs postInstallCommand after a successful MSI install" {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                assets = @([pscustomobject]@{ name = "App-Setup.msi"; browser_download_url = "https://example.com/App-Setup.msi" })
            }
        }
        Remove-Variable -Name postInstallRan -Scope Script -ErrorAction SilentlyContinue
        $package = [pscustomobject]@{
            content = "App"; repo = "someone/app"; assetPattern = "App-Setup.msi"
            postInstallCommand = 'Set-Variable -Name postInstallRan -Value $true -Scope Script'
        }

        Install-WinUtilProgramGithub -Packages @($package)

        $script:postInstallRan | Should -BeTrue
        Remove-Variable -Name postInstallRan -Scope Script -ErrorAction SilentlyContinue
    }

    It "does not run postInstallCommand after a failed MSI install" {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                assets = @([pscustomobject]@{ name = "App-Setup.msi"; browser_download_url = "https://example.com/App-Setup.msi" })
            }
        }
        Mock Start-WinUtilProcessAsStandardUser { [pscustomobject]@{ ExitCode = 1603 } }
        Remove-Variable -Name postInstallRan -Scope Script -ErrorAction SilentlyContinue
        $package = [pscustomobject]@{
            content = "App"; repo = "someone/app"; assetPattern = "App-Setup.msi"
            postInstallCommand = 'Set-Variable -Name postInstallRan -Value $true -Scope Script'
        }

        Install-WinUtilProgramGithub -Packages @($package)

        $script:postInstallRan | Should -BeNullOrEmpty
    }

    It "does not require a postInstallCommand" {
        $package = [pscustomobject]@{ content = "Clicker"; repo = "mackid1993/Clicker"; assetPattern = "Clicker-Setup-*.exe" }

        { Install-WinUtilProgramGithub -Packages @($package) } | Should -Not -Throw
    }

    Context "portable packages (no setup wizard, never register in Add/Remove Programs)" {
        BeforeEach {
            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    assets = @([pscustomobject]@{ name = "PlutoForChannels.exe"; browser_download_url = "https://example.com/PlutoForChannels.exe" })
                }
            }
        }

        It "moves the downloaded asset into its fixed install folder and launches it from there, not from TEMP" {
            # Regression guard for the actual reported bug: Pluto for Channels was launched
            # straight out of %TEMP% (the same as any other github-type install), then Uninstall-
            # WinUtilProgramGithub's Add/Remove Programs lookup always failed for it, since a
            # portable exe never registers itself there - confirmed via its own repo docs
            # ("doesn't register itself in Windows' Add/Remove Programs").
            $installDir = Get-WinUtilPortableGithubInstallDir -Name "Pluto for Channels"
            $package = [pscustomobject]@{ content = "Pluto for Channels"; repo = "nuken/Pluto-Windows_4C"; assetPattern = "PlutoForChannels*.exe"; portable = $true }

            Install-WinUtilProgramGithub -Packages @($package)

            Should -Invoke -CommandName New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq $installDir }
            Should -Invoke -CommandName Move-Item -Times 1 -Exactly -ParameterFilter {
                $Destination -eq (Join-Path $installDir "PlutoForChannels.exe")
            }
            Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq (Join-Path $installDir "PlutoForChannels.exe")
            }
        }

        It "stops a previous run of the app before overwriting its files, so a reinstall isn't blocked by a file lock" {
            # Regression guard: this delegates to Stop-WinUtilProcessByAssetPattern - see that
            # function's own docstring for the multi-round history of why (two PowerShell-side
            # Get-Process approaches, then a first taskkill /IM attempt, were all confirmed live
            # to still silently miss Pluto for Channels' actual running process).
            $package = [pscustomobject]@{ content = "Pluto for Channels"; repo = "nuken/Pluto-Windows_4C"; assetPattern = "PlutoForChannels*.exe"; portable = $true }

            Install-WinUtilProgramGithub -Packages @($package)

            Should -Invoke -CommandName Stop-WinUtilProcessByAssetPattern -Times 1 -Exactly -ParameterFilter {
                $AssetPattern -eq "PlutoForChannels*.exe"
            }
        }
    }
}
