#===========================================================================
# Tests - Install and Uninstall Workflows
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPackageLogSummary.ps1")
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPackagesInDependencyOrder.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPrerequisites.ps1")
    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPackagePrompts.ps1")
    . (Join-Path $script:repoRoot "functions\private\New-WinUtilStepProgressCallback.ps1")
    . (Join-Path $script:repoRoot "functions\public\Invoke-WPFInstall.ps1")
    . (Join-Path $script:repoRoot "functions\public\Invoke-WPFUnInstall.ps1")

    function Show-WinUtilMessage {
        param($Message, $Title, $Button, $Icon)
    }
    function Show-CustomDialog {
        param($Title, $Message, $Items, $Buttons, $Width, $Height, $EnableScroll)
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
        param($Action, $Programs, $ProgressCallback)
    }
    function Install-WinUtilFeatureWSL {
        param($Packages, $ProgressCallback)
    }
    function Install-WinUtilWSLDistro {
        param($Packages, $ProgressCallback)
    }
    function Install-WinUtilProgramDirect {
        param($Packages, $ProgressCallback)
    }
    function Install-WinUtilProgramGithub {
        param($Packages, $ProgressCallback)
    }
    function Install-WinUtilProgramNpm {
        param($Action, $Packages, $ProgressCallback)
    }
    function Install-WinUtilWSLCommand {
        param($Action, $Packages, $ProgressCallback)
    }
    function Install-WinUtilStreamLinkManager {
        param($Packages, $ProgressCallback)
    }
    function Uninstall-WinUtilProgramDirect {
        param($Packages, $ProgressCallback)
    }
    function Uninstall-WinUtilProgramGithub {
        param($Packages, $ProgressCallback)
    }
    function Uninstall-WinUtilStreamLinkManager {
        param($Packages, $ProgressCallback)
    }
    function Uninstall-WinUtilWSLDistro {
        param($Packages, $ProgressCallback)
    }
    function Uninstall-WinUtilFeatureWSL {
        param($Packages, $ProgressCallback)
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

        # Matches the real catalog object shape (config/applications.json) exactly - "content"
        # and "description" only, no separate "Name"/"Description" fields. An earlier version of
        # this fixture carried both, which meant Invoke-WPFUnInstall.ps1's own real bug (its
        # confirmation dialog selected "Name"/"Description" - fields that don't exist on real
        # catalog objects, only "content"/"description" do - leaving the Name column blank for
        # every app) went undetected here: the fixture's extra "Name" field happened to satisfy
        # the dialog's (wrong) property lookup even though production objects never have one.
        [pscustomobject]@{
            content = $Name
            description = "$Name package"
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
            [string[]]$Choco = @(),
            [object[]]$Direct = @(),
            [object[]]$Github = @(),
            [object[]]$Npm = @(),
            [object[]]$WslCommand = @(),
            [object[]]$StreamLinkManager = @()
        )

        # Real Get-WinUtilSelectedPackages always returns all 9 buckets as actual (possibly
        # empty) collections, never a missing key - @() on a truly missing/$null key wraps it
        # as a one-element array (Count 1, not 0), so leaving buckets out here would make the
        # runspace body think there's WSL/direct/etc work to do when there isn't any.
        $packages = @{}
        foreach ($bucketName in @("Winget", "Choco", "Direct", "Github", "Npm", "WslFeature", "WslDistro", "WslCommand", "StreamLinkManager")) {
            $packages[$bucketName] = [System.Collections.Generic.List[object]]::new()
        }

        foreach ($package in $Winget) {
            $null = $packages["Winget"].Add($package)
        }

        foreach ($package in $Choco) {
            $null = $packages["Choco"].Add($package)
        }

        foreach ($package in $Direct) { $null = $packages["Direct"].Add($package) }
        foreach ($package in $Github) { $null = $packages["Github"].Add($package) }
        foreach ($package in $Npm) { $null = $packages["Npm"].Add($package) }
        foreach ($package in $WslCommand) { $null = $packages["WslCommand"].Add($package) }
        foreach ($package in $StreamLinkManager) { $null = $packages["StreamLinkManager"].Add($package) }

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
        Mock Set-WinUtilTweaksProgressIndicator { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedInstallScriptBlock -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedInstallParameterList -Scope Script -ErrorAction SilentlyContinue
    }

    It "shows the progress bar immediately, before prerequisite/prompt resolution or the background runspace starts" {
        # Regression guard: confirmed live, a click that goes on to do real work (checking
        # prerequisites, resolving prompts, spinning up the background runspace) showed nothing
        # at all until the runspace itself got around to its own first progress update - a click
        # that looked like it did nothing.
        Invoke-WPFInstall

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Preparing install..." -and $Percent -eq 0
        }
    }

    It "does not show the progress bar when there's nothing selected or an install is already running" {
        New-WinUtilInstallTestContext

        Invoke-WPFInstall

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 0 -Exactly
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
        Mock Install-WinUtilProgramDirect { }
        Mock Install-WinUtilProgramGithub { }
        Mock Install-WinUtilProgramNpm { }
        Mock Install-WinUtilWSLCommand { }
        Mock Install-WinUtilStreamLinkManager { }
        Mock Install-WinUtilFeatureWSL { }
        Mock Install-WinUtilWSLDistro { }
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

    It "runs postInstallCommand after a package installs successfully via choco too" {
        # Regression guard: Docker Desktop declares both .winget and .choco (the user can
        # prefer either package manager), and its own engine doesn't start until launched at
        # least once after install - postInstallCommand needs to fire regardless of which
        # manager actually performed the install, not just winget.
        $dockerPackage = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; winget = "Docker.DockerDesktop"; choco = "docker-desktop"; postInstallCommand = 'Set-Variable -Name postInstallRan -Value $true -Scope Script' }
        New-WinUtilInstallTestContext -Packages @($dockerPackage)
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Winget @() -Choco @("docker-desktop")
        }
        Mock Install-WinUtilProgramChoco { @([pscustomobject]@{ Program = "docker-desktop"; Success = $true; ExitCode = 0 }) }

        Invoke-WPFInstall
        & $script:capturedInstallScriptBlock -PackagesToInstall @($dockerPackage) -ManagerPreference "Choco"

        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Message -like "Running post-install step for Docker Desktop*"
        }
        $script:postInstallRan | Should -BeTrue

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

    It "installs each package in a direct-download-style bucket one at a time, with its own progress step, not the whole bucket in one call" {
        # Regression guard: these buckets used to be handed to the installer as one call with
        # the whole array - a bucket with more than one package showed no progress movement
        # between them, and (confirmed live for a single-package bucket, Streaming Library
        # Manager) the label sat frozen for however long the entire call took.
        $pkgA = [pscustomobject]@{ content = "AppA"; url = "https://example.com/a.exe" }
        $pkgB = [pscustomobject]@{ content = "AppB"; url = "https://example.com/b.exe" }
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Direct @($pkgA, $pkgB)
        }

        Invoke-WPFInstall
        & $script:capturedInstallScriptBlock -PackagesToInstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Install-WinUtilProgramDirect -Times 2 -Exactly
        Should -Invoke -CommandName Install-WinUtilProgramDirect -Times 1 -Exactly -ParameterFilter {
            @($Packages).Count -eq 1 -and $Packages[0].content -eq "AppA"
        }
        Should -Invoke -CommandName Install-WinUtilProgramDirect -Times 1 -Exactly -ParameterFilter {
            @($Packages).Count -eq 1 -and $Packages[0].content -eq "AppB"
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Label -eq "Installing AppA (1/2)" -and $Percent -eq 0
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Label -eq "Installed AppA (1/2)" -and $Percent -eq 50
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Label -eq "Installing AppB (2/2)" -and $Percent -eq 50
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Label -eq "Installed AppB (2/2)" -and $Percent -eq 100
        }
    }

    It "advances Percent (not just Label) as an installer reports each of its own milestones" {
        # Regression guard for the actual reported bug: an earlier version of this wiring only
        # updated Label on each -ProgressCallback call, leaving Percent frozen at the package's
        # starting value until the whole package finished and jumped straight to the next one -
        # confirmed live, this looked identical to the original "frozen bar" bug it was meant to
        # fix, just with the label text changing underneath a still-static bar. Direct-type
        # packages report exactly 2 milestones (downloading, installing), so with this package
        # alone occupying the full [0, 100] slot, each call should land on 50 and 100 exactly -
        # the same even division "Show Installed Apps" uses per app, not a partial nudge that
        # never actually reaches the package's own end percent.
        $pkg = [pscustomobject]@{ content = "AppA"; url = "https://example.com/a.exe" }
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Direct @($pkg)
        }
        Mock Install-WinUtilProgramDirect {
            param($Packages, $ProgressCallback)
            & $ProgressCallback "Downloading AppA..."
            & $ProgressCallback "Installing AppA..."
        }

        Invoke-WPFInstall
        & $script:capturedInstallScriptBlock -PackagesToInstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Downloading AppA..." -and $Percent -eq 50
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Installing AppA..." -and $Percent -eq 100
        }
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

        Mock Show-WinUtilMessage { "OK" }
        Mock Show-CustomDialog { "Yes" }
        Mock Invoke-WPFRunspace {
            $script:capturedUninstallScriptBlock = $ScriptBlock
            $script:capturedUninstallParameterList = $ParameterList
            [pscustomobject]@{ MockHandle = $true }
        }
        Mock Write-WinUtilLog { }
        Mock Set-WinUtilTweaksProgressIndicator { }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedUninstallScriptBlock -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedUninstallParameterList -Scope Script -ErrorAction SilentlyContinue
    }

    It "shows the progress bar immediately after confirmation, before the background runspace starts" {
        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Preparing uninstall..." -and $Percent -eq 0
        }
    }

    It "does not show the progress bar when uninstall is declined" {
        Mock Show-CustomDialog { "No" } -ParameterFilter { $Title -eq "Are you sure?" }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 0 -Exactly
    }

    It "confirms and queues selected packages with the configured package manager preference" {
        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        Should -Invoke -CommandName Show-CustomDialog -Times 1 -Exactly -ParameterFilter {
            # Regression guard for two real production bugs: first, the confirmation dialog
            # selected "Name"/"Description" - fields that don't exist on real catalog objects
            # (only "content"/"description" do) - leaving the Name column blank for every app
            # regardless of selection. Second, even after that fix, the plain-text "table" it
            # built via Select-Object/Out-String never actually lined up in a real MessageBox,
            # which uses a proportional font, not a monospaced one - Show-CustomDialog's -Items
            # renders real rows instead, so this checks the item data itself (not string
            # formatting) reaches it correctly.
            $Message -like "*This will uninstall the following applications:*" -and
                $Title -eq "Are you sure?" -and
                $Buttons -eq "YesNo" -and
                @($Items).Count -eq 1 -and
                @($Items)[0].Name -eq "Git" -and
                @($Items)[0].Description -eq "Git package"
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
        Mock Show-CustomDialog { "No" } -ParameterFilter { $Title -eq "Are you sure?" }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)

        Should -Invoke -CommandName Invoke-WPFRunspace -Times 0 -Exactly
    }
}

Describe "Invoke-WPFUnInstall runspace body" {
    BeforeEach {
        $script:package = New-WinUtilPackage
        New-WinUtilInstallTestContext -Packages @($script:package)
        $script:capturedUninstallScriptBlock = $null

        Mock Show-CustomDialog { "Yes" }
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
        Mock Install-WinUtilProgramNpm { }
        Mock Install-WinUtilWSLCommand { }
        Mock Uninstall-WinUtilProgramDirect { }
        Mock Uninstall-WinUtilProgramGithub { }
        Mock Uninstall-WinUtilStreamLinkManager { }
        Mock Uninstall-WinUtilWSLDistro { }
        Mock Uninstall-WinUtilFeatureWSL { }
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

    It "uninstalls each package in a direct-uninstall-style bucket one at a time, with its own progress step" {
        $pkgA = [pscustomobject]@{ content = "AppA"; uninstallCommand = "Remove-Item C:\AppA" }
        $pkgB = [pscustomobject]@{ content = "AppB"; uninstallCommand = "Remove-Item C:\AppB" }
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Direct @($pkgA, $pkgB)
        }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)
        & $script:capturedUninstallScriptBlock -PackagesToUninstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Uninstall-WinUtilProgramDirect -Times 2 -Exactly
        Should -Invoke -CommandName Uninstall-WinUtilProgramDirect -Times 1 -Exactly -ParameterFilter {
            @($Packages).Count -eq 1 -and $Packages[0].content -eq "AppA"
        }
        Should -Invoke -CommandName Uninstall-WinUtilProgramDirect -Times 1 -Exactly -ParameterFilter {
            @($Packages).Count -eq 1 -and $Packages[0].content -eq "AppB"
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Label -eq "Uninstalling AppA (1/2)" -and $Percent -eq 0
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Label -eq "Uninstalling AppB (2/2)" -and $Percent -eq 50
        }
    }

    It "advances Percent (not just Label) as an uninstaller reports its own milestones" {
        # Regression guard for the actual reported bug - see Invoke-WPFInstall's matching test
        # for the full explanation. Direct's uninstall ExpectedSteps is 2 (covering its
        # higher-step uninstallViaInstaller branch), but this package's uninstallCommand branch
        # only ever calls back once - landing on 50, not 100, is the documented, accepted
        # imprecision for that mismatch (New-WinUtilStepProgressCallback's own docstring), not a
        # bug: the caller's own authoritative "Uninstalled AppA (1/1)" call right after this
        # still snaps Percent to the real end value regardless.
        $pkg = [pscustomobject]@{ content = "AppA"; uninstallCommand = "Remove-Item C:\AppA" }
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Direct @($pkg)
        }
        Mock Uninstall-WinUtilProgramDirect {
            param($Packages, $ProgressCallback)
            & $ProgressCallback "Uninstalling AppA..."
        }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)
        & $script:capturedUninstallScriptBlock -PackagesToUninstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Visible -eq $true -and $Label -eq "Uninstalling AppA..." -and $Percent -eq 50
        }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter {
            $Label -eq "Uninstalled AppA (1/1)" -and $Percent -eq 100
        }
    }

    It "attempts a github-install package via Uninstall-WinUtilProgramGithub instead of routing it straight to unsupported" {
        # Regression guard: every github-type package used to be unconditionally added to the
        # "unsupported" list with no attempt at all - now that Uninstall-WinUtilProgramGithub
        # can look up a registered Windows uninstaller by DisplayName, every selected one should
        # actually be tried instead of being written off upfront.
        $pkg = [pscustomobject]@{ content = "Clicker" }
        Mock Get-WinUtilSelectedPackages {
            New-WinUtilPackageSplit -Github @($pkg)
        }

        Invoke-WPFUnInstall -PackagesToUninstall @($script:package)
        & $script:capturedUninstallScriptBlock -PackagesToUninstall @($script:package) -ManagerPreference "Winget"

        Should -Invoke -CommandName Uninstall-WinUtilProgramGithub -Times 1 -Exactly -ParameterFilter {
            @($Packages).Count -eq 1 -and $Packages[0].content -eq "Clicker"
        }
        Should -Invoke -CommandName Invoke-WPFUIThread -Times 0 -Exactly -ParameterFilter {
            $ScriptBlock.ToString() -like '*Some apps were skipped*'
        }
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
