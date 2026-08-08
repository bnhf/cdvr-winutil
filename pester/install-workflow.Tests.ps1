#===========================================================================
# Tests - Install and Uninstall Workflows
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPackageLogSummary.ps1")
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPackagesInDependencyOrder.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPrerequisites.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPackagePrompts.ps1")
    . (Join-Path $script:repoRoot "functions\public\Invoke-WPFInstall.ps1")
    . (Join-Path $script:repoRoot "functions\public\Invoke-WPFUnInstall.ps1")

    function Show-WinUtilMessage {
        param($Message, $Title, $Button, $Icon)
    }
    function Show-WinUtilPromptDialog {
        param($Title, $Message, $Prompts)
    }
    function Test-WinUtilProgramInstalled {
        param($WingetId, $ChocoId)
        $false
    }
    function Test-WinUtilWSLFeatureEnabled { $false }
    function Test-WinUtilWSLDistroInstalled {
        param($Distro)
        $false
    }
    function Test-WinUtilVirtualizationFirmwareEnabled { $true }
    function Invoke-WPFRunspace {
        param($ArgumentList, $ParameterList, [scriptblock]$ScriptBlock)
    }
    function Get-WinUtilSelectedPackages {
        param($PackageList, [string]$Preference)
    }
    function Set-WinUtilTweaksProgressIndicator {
        param($Visible, $Label, $Percent)
    }
    function Install-WinUtilWinget { }
    function Install-WinUtilChoco { }
    function Install-WinUtilProgramWinget {
        param($Action, $Programs)
    }
    function Install-WinUtilProgramChoco {
        param($Action, $Programs)
    }
    function Install-WinUtilFeatureWSL {
        param($Packages)
    }
    function Install-WinUtilWSLDistro {
        param($Packages)
    }
    function Invoke-WPFUIThread {
        param([scriptblock]$ScriptBlock)
    }
    function Write-WinUtilLog {
        param($Message, $Level, $Component)
    }

    function script:New-WinUtilPackage {
        param(
            [string]$Name = "Git",
            [string]$Winget = "Git.Git",
            [string]$Choco = "git"
        )

        [pscustomobject]@{
            Name = $Name
            content = $Name
            Description = "$Name package"
            winget = $Winget
            choco = $Choco
        }
    }

    function script:New-WinUtilInstallTestContext {
        param(
            [bool]$ProcessRunning = $false,
            [object[]]$Packages = @()
        )

        $applications = @{}
        $selectedApps = [System.Collections.Generic.List[string]]::new()

        for ($i = 0; $i -lt $Packages.Count; $i++) {
            $key = "WPFInstallTest$i"
            $applications[$key] = $Packages[$i]
            $selectedApps.Add($key)
        }

        $script:sync = [Hashtable]::Synchronized(@{
            ProcessRunning = $ProcessRunning
            selectedApps = $selectedApps
            preferences = [pscustomobject]@{
                packagemanager = "Winget"
            }
            Form = [pscustomobject]@{
                Dispatcher = [pscustomobject]@{}
            }
            configs = @{
                applicationsHashtable = $applications
            }
        })
    }

    function script:New-WinUtilPackageSplit {
        param(
            [string[]]$Winget = @(),
            [string[]]$Choco = @()
        )

        # Real Get-WinUtilSelectedPackages always returns all 9 buckets as actual (possibly
        # empty) collections, never a missing key - @() on a truly missing/$null key wraps it
        # as a one-element array (Count 1, not 0), so leaving buckets out here would make the
        # runspace body think there's WSL/direct/etc work to do when there isn't any.
        $packages = @{}
        foreach ($bucketName in @("Winget", "Choco", "Direct", "Github", "Npm", "WslFeature", "WslDistro", "WslCommand", "StreamLinkManager")) {
            $packages[$bucketName] = [System.Collections.Generic.List[string]]::new()
        }

        foreach ($package in $Winget) {
            $null = $packages["Winget"].Add($package)
        }

        foreach ($package in $Choco) {
            $null = $packages["Choco"].Add($package)
        }

        $packages
    }
}

Describe "Invoke-WPFInstall entrypoint" {
    BeforeEach {
        $script:package = New-WinUtilPackage
        New-WinUtilInstallTestContext -Packages @($script:package)
        $script:capturedInstallScriptBlock = $null
        $script:capturedInstallParameterList = $null

        Mock Show-WinUtilMessage { "OK" }
        Mock Invoke-WPFRunspace {
            $script:capturedInstallScriptBlock = $ScriptBlock
            $script:capturedInstallParameterList = $ParameterList
            [pscustomobject]@{ MockHandle = $true }
        }
        Mock Write-WinUtilLog { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedInstallScriptBlock -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedInstallParameterList -Scope Script -ErrorAction SilentlyContinue
    }

    It "queues selected packages with the configured package manager preference" {
        Invoke-WPFInstall

        Should -Invoke -CommandName Invoke-WPFRunspace -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock -is [scriptblock] -and
                $ParameterList.Count -eq 2 -and
                $ParameterList[0][0] -eq "PackagesToInstall" -and
                @($ParameterList[0][1]).Count -eq 1 -and
                @($ParameterList[0][1])[0].winget -eq "Git.Git" -and
                $ParameterList[1][0] -eq "ManagerPreference" -and
                $ParameterList[1][1] -eq "Winget"
        }
        Should -Invoke -CommandName Show-WinUtilMessage -Times 0 -Exactly
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Component -eq "Install" -and
                $Message -eq "Install selected package(s): Git (winget: Git.Git)"
        }
    }

    It "queues the explicit app popup package over the selected apps" {
        $explicitPackage = New-WinUtilPackage -Name "VLC" -Winget "VideoLAN.VLC" -Choco "vlc"

        Invoke-WPFInstall -PackagesToInstall $explicitPackage

        Should -Invoke -CommandName Invoke-WPFRunspace -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock -is [scriptblock] -and
                $ParameterList.Count -eq 2 -and
                $ParameterList[0][0] -eq "PackagesToInstall" -and
                @($ParameterList[0][1]).Count -eq 1 -and
                @($ParameterList[0][1])[0].winget -eq "VideoLAN.VLC" -and
                $ParameterList[1][0] -eq "ManagerPreference" -and
                $ParameterList[1][1] -eq "Winget"
        }
        Should -Invoke -CommandName Show-WinUtilMessage -Times 0 -Exactly
    }

    It "prompts and exits when no packages are selected" {
        New-WinUtilInstallTestContext

        Invoke-WPFInstall

        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter {
            $Message -eq "Please select the program(s) to install or upgrade." -and
                $Title -eq "WinUtil" -and
                $Button -eq "OK" -and
                $Icon -eq "Warning"
        }
        Should -Invoke -CommandName Invoke-WPFRunspace -Times 0 -Exactly
    }

    It "prompts and exits when another install process is running" {
        New-WinUtilInstallTestContext -ProcessRunning $true -Packages @($script:package)

        Invoke-WPFInstall

        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter {
            $Message -eq "[Invoke-WPFInstall] An Install process is currently running." -and
                $Title -eq "WinUtil" -and
                $Button -eq "OK" -and
                $Icon -eq "Warning"
        }
        Should -Invoke -CommandName Invoke-WPFRunspace -Times 0 -Exactly
    }
}

Describe "Invoke-WPFInstall runspace body" {
    BeforeEach {
        $script:package = New-WinUtilPackage
        New-WinUtilInstallTestContext -Packages @($script:package)
        $script:capturedInstallScriptBlock = $null

        Mock Show-WinUtilMessage { "OK" }
        Mock Invoke-WPFRunspace {
            $script:capturedInstallScriptBlock = $ScriptBlock
            [pscustomobject]@{ MockHandle = $true }
        }
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Winget @("Git.Git") -Choco @("vlc")
        }
        Mock Set-WinUtilTweaksProgressIndicator { }
        Mock Install-WinUtilWinget { }
        Mock Install-WinUtilChoco { }
        Mock Install-WinUtilProgramWinget { }
        Mock Install-WinUtilProgramChoco { }
        Mock Invoke-WPFUIThread { }
        Mock Write-WinUtilLog { }
        Mock Write-Host { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedInstallScriptBlock -Scope Script -ErrorAction SilentlyContinue
    }

    It "installs split winget and choco packages and cleans up on success" {
        Invoke-WPFInstall

        & $script:capturedInstallScriptBlock -PackagesToInstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Get-WinUtilSelectedPackages -Times 1 -Exactly -ParameterFilter {
            @($PackageList).Count -eq 1 -and $Preference -eq "Winget"
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Preparing app install (0/2)" -and $Percent -eq 0
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Installed Git.Git (1/2)" -and $Percent -eq 50
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Installed Chocolatey packages (2/2)" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "App install finished" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Install-WinUtilWinget -Times 1 -Exactly
        Should -Invoke -CommandName Install-WinUtilProgramWinget -Times 1 -Exactly -ParameterFilter {
            $Action -eq "Install" -and @($Programs)[0] -eq "Git.Git"
        }
        Should -Invoke -CommandName Install-WinUtilChoco -Times 1 -Exactly
        Should -Invoke -CommandName Install-WinUtilProgramChoco -Times 1 -Exactly -ParameterFilter {
            $Action -eq "Install" -and @($Programs)[0] -eq "vlc"
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $false*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $true*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"*'
        }
        $script:sync.ProcessRunning | Should -BeFalse
    }

    It "runs postInstallCommand after a package installs successfully via winget" {
        # Regression guard: Debian moving to a winget install meant its first-run OOBE prompt
        # (creating a Linux user/password) needed a real interactive console, which "wsl -d
        # Debian" from an existing terminal was confirmed NOT to reliably provide. Launching it
        # right after install, via a postInstallCommand declared on the catalog entry, gets that
        # console started immediately instead of leaving the user to remember a manual step.
        $debianPackage = [pscustomobject]@{ Key = "debian"; content = "Debian (WSL)"; winget = "Debian.Debian"; postInstallCommand = 'Set-Variable -Name postInstallRan -Value $true -Scope Script' }
        New-WinUtilInstallTestContext -Packages @($debianPackage)
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Winget @("Debian.Debian") -Choco @()
        }
        Mock Install-WinUtilProgramWinget { @([pscustomobject]@{ Program = "Debian.Debian"; Success = $true; ExitCode = 0 }) }

        Invoke-WPFInstall
        & $script:capturedInstallScriptBlock -PackagesToInstall @($debianPackage) -ManagerPreference "Winget"

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Message -like "Running post-install step for Debian (WSL)*"
        }
        $script:postInstallRan | Should -BeTrue

        Remove-Variable -Name postInstallRan -Scope Script -ErrorAction SilentlyContinue
    }

    It "does not run postInstallCommand when the winget install itself fails" {
        $debianPackage = [pscustomobject]@{ Key = "debian"; content = "Debian (WSL)"; winget = "Debian.Debian"; postInstallCommand = 'Set-Variable -Name postInstallRan -Value $true -Scope Script' }
        New-WinUtilInstallTestContext -Packages @($debianPackage)
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Winget @("Debian.Debian") -Choco @()
        }
        Mock Install-WinUtilProgramWinget { @([pscustomobject]@{ Program = "Debian.Debian"; Success = $false; ExitCode = 1 }) }

        Invoke-WPFInstall
        & $script:capturedInstallScriptBlock -PackagesToInstall @($debianPackage) -ManagerPreference "Winget"

        $script:postInstallRan | Should -BeNullOrEmpty
        Remove-Variable -Name postInstallRan -Scope Script -ErrorAction SilentlyContinue
    }

    It "installs WSL2/Debian before winget/choco, so Docker Desktop doesn't try to install before its own WSL2 prerequisite is even enabled" {
        Mock Get-WinUtilSelectedPackages {
            $split = New-WinUtilPackageSplit -Winget @("Docker.DockerDesktop") -Choco @()
            $split["WslFeature"].Add("wsl2")
            $split["WslDistro"].Add("debian")
            $split
        }
        $script:callOrder = [System.Collections.Generic.List[string]]::new()
        Mock Install-WinUtilFeatureWSL { $script:callOrder.Add("wslFeature") }
        Mock Install-WinUtilWSLDistro { $script:callOrder.Add("wslDistro") }
        Mock Install-WinUtilProgramWinget { $script:callOrder.Add("winget") }
        Mock Install-WinUtilProgramChoco { $script:callOrder.Add("choco") }

        Invoke-WPFInstall
        & $script:capturedInstallScriptBlock -PackagesToInstall @($script:package) -ManagerPreference "Winget"

        $script:callOrder | Should -Be @("wslFeature", "wslDistro", "winget")
        Remove-Variable -Name callOrder -Scope Script -ErrorAction SilentlyContinue
    }

    It "does not crash when a package-manager bucket is null instead of an empty collection" {
        # Regression guard for a real production crash: "Cannot bind argument to parameter
        # 'Packages' because it is null." @($null).Count is 1, not 0, so a bucket that's $null
        # (rather than a real empty collection) used to slip past the "is this bucket empty"
        # check and get passed straight through to an installer function's Mandatory
        # [object[]] parameter.
        Mock Get-WinUtilSelectedPackages {
            $split = New-WinUtilPackageSplit -Winget @("Docker.DockerDesktop") -Choco @()
            $split["WslFeature"] = $null
            $split["WslDistro"].Add("debian")
            $split
        }
        Mock Install-WinUtilFeatureWSL { }
        Mock Install-WinUtilWSLDistro { }

        { Invoke-WPFInstall; & $script:capturedInstallScriptBlock -PackagesToInstall @($script:package) -ManagerPreference "Winget" } | Should -Not -Throw

        Should -Invoke -CommandName Install-WinUtilFeatureWSL -Times 0 -Exactly
        Should -Invoke -CommandName Install-WinUtilWSLDistro -Times 1 -Exactly -ParameterFilter { @($Packages) -join "|" -eq "debian" }
    }

    It "shows failure progress, sets taskbar error state, and clears ProcessRunning on failure" {
        Mock Install-WinUtilProgramWinget { throw "winget failed" }

        Invoke-WPFInstall

        & $script:capturedInstallScriptBlock -PackagesToInstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "App install failed" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $false*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $true*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*Set-WinUtilTaskbaritem -state "Error" -overlay "warning"*'
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Component -eq "Install" -and $Message -like "Install workflow failed:*"
        }
        $script:sync.ProcessRunning | Should -BeFalse
    }

    It "shows a failure summary and warning overlay - not a checkmark - when a package fails without throwing" {
        # Regression guard: this is the actual bug report - Install-WinUtilProgramWinget/Choco
        # returning a per-item failure (not a thrown exception) must not be reported as a clean
        # success. Invoke-WPFUIThread is mocked as a no-op here (matching the rest of this
        # file's pattern), so the scriptblock's own source text is what's asserted on rather
        # than its executed effects.
        Mock Install-WinUtilProgramWinget { @([pscustomobject]@{ Program = "Git.Git"; Success = $false; ExitCode = 1 }) }

        Invoke-WPFInstall
        & $script:capturedInstallScriptBlock -PackagesToInstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "App install finished with errors" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            # The scriptblock's source text references $failedList by name, not its interpolated
            # value (ToString() on a scriptblock returns its literal source, not a rendered
            # string) - so this checks for the static parts, not the package name itself.
            $ScriptBlock.ToString() -like '*Set-WinUtilTaskbaritem -state "None" -overlay "warning"*' -and
                $ScriptBlock.ToString() -like '*Some installs failed*' -and
                $ScriptBlock.ToString() -like '*$failedList*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 0 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*overlay "checkmark"*'
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            # Confirms the friendly display name ("Git", from the package's .content field) was
            # resolved from the raw winget ID ("Git.Git") for the failure report.
            $Level -eq "WARN" -and $Component -eq "Install" -and $Message -like "Install workflow completed with failures: Git*"
        }
        $script:sync.ProcessRunning | Should -BeFalse
    }
}

Describe "Invoke-WPFUnInstall entrypoint" {
    BeforeEach {
        $script:package = New-WinUtilPackage
        New-WinUtilInstallTestContext -Packages @($script:package)
        $script:capturedUninstallScriptBlock = $null
        $script:capturedUninstallParameterList = $null

        Mock Show-WinUtilMessage { "Yes" }
        Mock Invoke-WPFRunspace {
            $script:capturedUninstallScriptBlock = $ScriptBlock
            $script:capturedUninstallParameterList = $ParameterList
            [pscustomobject]@{ MockHandle = $true }
        }
        Mock Write-WinUtilLog { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedUninstallScriptBlock -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedUninstallParameterList -Scope Script -ErrorAction SilentlyContinue
    }

    It "confirms and queues selected packages with the configured package manager preference" {
        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter {
            $Message -like "*This will uninstall the following applications:*" -and
                $Message -like "*Git*" -and
                $Title -eq "Are you sure?" -and
                "$Button" -eq "YesNo" -and
                "$Icon" -eq "Information"
        }
        Should -Invoke -CommandName Invoke-WPFRunspace -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock -is [scriptblock] -and
                $ParameterList.Count -eq 2 -and
                $ParameterList[0][0] -eq "PackagesToUninstall" -and
                @($ParameterList[0][1]).Count -eq 1 -and
                @($ParameterList[0][1])[0].winget -eq "Git.Git" -and
                $ParameterList[1][0] -eq "ManagerPreference" -and
                $ParameterList[1][1] -eq "Winget"
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Component -eq "Uninstall" -and
                $Message -eq "Uninstall selected package(s): Git (winget: Git.Git)"
        }
    }

    It "prompts and exits when no packages are selected" {
        Invoke-WPFUnInstall -PackagesToUninstall @()

        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter {
            $Message -eq "Please select the program(s) to uninstall" -and
                $Title -eq "WinUtil" -and
                $Button -eq "OK" -and
                $Icon -eq "Warning"
        }
        Should -Invoke -CommandName Invoke-WPFRunspace -Times 0 -Exactly
    }

    It "prompts and exits when another install process is running" {
        $script:sync.ProcessRunning = $true

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter {
            $Message -eq "[Invoke-WPFUnInstall] Install process is currently running" -and
                $Title -eq "WinUtil" -and
                $Button -eq "OK" -and
                $Icon -eq "Warning"
        }
        Should -Invoke -CommandName Invoke-WPFRunspace -Times 0 -Exactly
    }

    It "exits without queueing uninstall when confirmation is declined" {
        Mock Show-WinUtilMessage { "No" } -ParameterFilter { $Title -eq "Are you sure?" }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        Should -Invoke -CommandName Invoke-WPFRunspace -Times 0 -Exactly
    }
}

Describe "Invoke-WPFUnInstall runspace body" {
    BeforeEach {
        $script:package = New-WinUtilPackage
        New-WinUtilInstallTestContext -Packages @($script:package)
        $script:capturedUninstallScriptBlock = $null

        Mock Show-WinUtilMessage { "Yes" }
        Mock Invoke-WPFRunspace {
            $script:capturedUninstallScriptBlock = $ScriptBlock
            [pscustomobject]@{ MockHandle = $true }
        }
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Winget @("Git.Git") -Choco @("vlc")
        }
        Mock Set-WinUtilTweaksProgressIndicator { }
        Mock Install-WinUtilProgramWinget { }
        Mock Install-WinUtilProgramChoco { }
        Mock Invoke-WPFUIThread { }
        Mock Write-WinUtilLog { }
        Mock Write-Host { }
        Mock New-Item { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedUninstallScriptBlock -Scope Script -ErrorAction SilentlyContinue
    }

    It "uninstalls split winget and choco packages and cleans up on success" {
        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        & $script:capturedUninstallScriptBlock -PackagesToUninstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Get-WinUtilSelectedPackages -Times 1 -Exactly -ParameterFilter {
            @($PackageList).Count -eq 1 -and $Preference -eq "Winget"
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Preparing app uninstall (0/2)" -and $Percent -eq 0
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Uninstalled Git.Git (1/2)" -and $Percent -eq 50
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Uninstalled Chocolatey packages (2/2)" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "App uninstall finished" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Install-WinUtilProgramWinget -Times 1 -Exactly -ParameterFilter {
            $Action -eq "Uninstall" -and @($Programs)[0] -eq "Git.Git"
        }
        Should -Invoke -CommandName Install-WinUtilProgramChoco -Times 1 -Exactly -ParameterFilter {
            $Action -eq "Uninstall" -and @($Programs)[0] -eq "vlc"
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $false*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $true*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"*'
        }
        $script:sync.ProcessRunning | Should -BeFalse
    }

    It "shows failure progress, sets taskbar error state, and clears ProcessRunning on failure" {
        Mock Install-WinUtilProgramWinget { throw "winget failed" }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        & $script:capturedUninstallScriptBlock -PackagesToUninstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "App uninstall failed" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $false*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*$sync.ItemsControl.IsEnabled = $true*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*Set-WinUtilTaskbaritem -state "Error" -overlay "warning"*'
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Component -eq "Uninstall" -and $Message -like "Uninstall workflow failed:*"
        }
        $script:sync.ProcessRunning | Should -BeFalse
    }

    It "shows a failure summary and warning overlay - not a checkmark - when a package fails without throwing" {
        # Regression guard for the actual reported bug: uninstalling VLC failed (winget's own
        # exit code was non-zero) but the progress bar still showed a completed/checkmark state,
        # because the failure was only logged, never surfaced. Install-WinUtilProgramWinget
        # returning a per-item failure (not a thrown exception) must produce a warning overlay
        # and a summary dialog, not a clean "finished" checkmark.
        Mock Install-WinUtilProgramWinget { @([pscustomobject]@{ Program = "Git.Git"; Success = $false; ExitCode = -1978335184 }) }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)
        & $script:capturedUninstallScriptBlock -PackagesToUninstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "App uninstall finished with errors" -and $Percent -eq 100
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 1 -Exactly -ParameterFilter {
            # The scriptblock's source text references $failedList by name, not its interpolated
            # value (ToString() on a scriptblock returns its literal source, not a rendered
            # string) - so this checks for the static parts, not the package name itself.
            $ScriptBlock.ToString() -like '*Set-WinUtilTaskbaritem -state "None" -overlay "warning"*' -and
                $ScriptBlock.ToString() -like '*Some uninstalls failed*' -and
                $ScriptBlock.ToString() -like '*$failedList*'
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 0 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*overlay "checkmark"*'
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            # Confirms the friendly display name ("Git", from the package's .content field) was
            # resolved from the raw winget ID ("Git.Git") for the failure report.
            $Level -eq "WARN" -and $Component -eq "Uninstall" -and $Message -like "Uninstall workflow completed with failures: Git*"
        }
        $script:sync.ProcessRunning | Should -BeFalse
    }
}
