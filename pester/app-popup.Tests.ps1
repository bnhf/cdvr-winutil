#===========================================================================
# Tests - App popup: hit-testable gaps between icons, and the "Open2" secondary launch target
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    Add-Type -AssemblyName PresentationFramework
    . (Join-Path $script:repoRoot "functions\public\Initialize-WPFUI.ps1")
    . (Join-Path $script:repoRoot "functions\private\Initialize-InstallAppEntry.ps1")

    function Invoke-WPFSelectedCheckboxesUpdate { param($type, $checkboxName) }
    function New-WinUtilFossBadge { New-Object Windows.Controls.Border }
    function Find-WinUtilAppLaunchTarget {
        param($AppName)
        if ($AppName -eq "WSL Settings") { "shell:AppsFolder\MicrosoftCorporationII.WindowsSubsystemForLinux_8wekyb3d8bbwe!App" } else { $null }
    }

    $script:sync = @{
        Form = [pscustomobject]@{
            Resources = @{}
        }
        WPFselectedAppsButton = New-Object Windows.Controls.Button
        configs = [pscustomobject]@{
            applicationsHashtable = @{
                wsl2 = [pscustomobject]@{
                    content = "WSL2"
                    installType = "wslFeature"
                    secondaryOpen = [pscustomobject]@{ label = "WSL Settings"; appName = "WSL Settings" }
                }
                olivetin = [pscustomobject]@{
                    content = "Olivetin EZ-Start"
                    webui = "http://localhost:1337"
                    secondaryOpen = [pscustomobject]@{ label = "Portainer"; webui = "http://localhost:9000" }
                }
                git = [pscustomobject]@{
                    content = "Git"
                    winget = "Git.Git"
                }
            }
        }
    }

    Initialize-WPFUI -TargetGridName "appscategory"

    # Simulates the app entry's own MouseRightButtonUp handler without a real Border/mouse
    # event - sets the same $sync state that handler sets, given just the app's catalog key.
    function script:Select-WinUtilPopupApp {
        param([string]$AppKey)

        $sync.appPopupSelectedApp = $AppKey
        if ($sync.appPopupOpen2Button) {
            $appObject = $sync.configs.applicationsHashtable.$AppKey
            $sync.appPopupOpen2Button.Visibility = if ($appObject.secondaryOpen) {
                [Windows.Visibility]::Visible
            } else {
                [Windows.Visibility]::Collapsed
            }
        }
    }

    function script:Send-WinUtilMouseEnter {
        param($Control)
        $Control.RaiseEvent((New-Object Windows.Input.MouseEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0) -Property @{ RoutedEvent = [Windows.UIElement]::MouseEnterEvent }))
    }

    function script:Send-WinUtilMouseLeave {
        param($Control)
        $Control.RaiseEvent((New-Object Windows.Input.MouseEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0) -Property @{ RoutedEvent = [Windows.UIElement]::MouseLeaveEvent }))
    }

    # DispatcherTimers (including $sync.appPopupCloseTimer) only tick while the Dispatcher is
    # actually pumping messages - normally the WPF message loop, which these tests never start
    # (no ShowDialog()/Run() here, unlike custom-dialog.Tests.ps1). Pushing a nested frame with
    # its own short-lived timer is the standard way to let queued Dispatcher work (including
    # OTHER timers) run for a bounded real-time window without a full modal loop.
    function script:Wait-WinUtilDispatcher {
        param([int]$Milliseconds)

        $frame = New-Object Windows.Threading.DispatcherFrame
        $waitTimer = New-Object Windows.Threading.DispatcherTimer
        $waitTimer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
        $waitTimer.Add_Tick({
            $waitTimer.Stop()
            $frame.Continue = $false
        })
        $waitTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }
}

Describe "App popup layout" {
    It "gives the button row an explicit (even if invisible) Background" {
        # Regression guard for the actual reported bug: a StackPanel with no Background at all
        # is hit-test transparent in the gaps BETWEEN its children (created by each button's own
        # margin) - MouseLeave fired the instant the mouse crossed from one icon toward the
        # next, closing the whole popup before its tooltip had a chance to show. An explicit
        # Transparent brush (still fully invisible) makes the whole panel - gaps included -
        # count as "inside" for hit-testing.
        $stackPanel = $sync.appPopup.Child
        $stackPanel.Background | Should -Not -BeNullOrEmpty
        $stackPanel | Should -BeOfType [Windows.Controls.StackPanel]
    }
}

Describe "App popup Open2 (secondary launch target)" {
    It "is collapsed for an app with no secondaryOpen declared" {
        Select-WinUtilPopupApp -AppKey "git"

        $sync.appPopupOpen2Button.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
    }

    It "is visible for an app that declares secondaryOpen" {
        Select-WinUtilPopupApp -AppKey "olivetin"

        $sync.appPopupOpen2Button.Visibility | Should -Be ([Windows.Visibility]::Visible)
    }

    It "resolves a webui-based secondary target (Olivetin -> Portainer) on hover" {
        Select-WinUtilPopupApp -AppKey "olivetin"
        Send-WinUtilMouseEnter -Control $sync.appPopupOpen2Button

        $sync.appPopupOpen2Button.Tag | Should -Be "http://localhost:9000"
        $sync.appPopupOpen2Button.ToolTip | Should -Match "Portainer"
    }

    It "resolves an appName-based secondary target (WSL2 -> WSL Settings) on hover" {
        # Regression guard: this is the one case that can't reuse "webui" - WSL Settings is a
        # native Start Menu app, not a local web server, so it goes through
        # Find-WinUtilAppLaunchTarget the same way the primary "Open" button already does for
        # community installers with no declared webui.
        Select-WinUtilPopupApp -AppKey "wsl2"
        Send-WinUtilMouseEnter -Control $sync.appPopupOpen2Button

        $sync.appPopupOpen2Button.Tag | Should -Be "shell:AppsFolder\MicrosoftCorporationII.WindowsSubsystemForLinux_8wekyb3d8bbwe!App"
        $sync.appPopupOpen2Button.ToolTip | Should -Match "WSL Settings"
    }
}

Describe "App popup close grace period" {
    BeforeEach {
        $sync.appPopupCloseTimer.Stop()
        $sync.appPopup.IsOpen = $true
    }

    It "closes the popup after the grace period when the mouse doesn't come back" {
        Send-WinUtilMouseLeave -Control $sync.appPopup.Child

        $sync.appPopup.IsOpen | Should -BeTrue
        Wait-WinUtilDispatcher -Milliseconds 600

        $sync.appPopup.IsOpen | Should -BeFalse
    }

    It "cancels the pending close if the mouse re-enters before the grace period elapses" {
        # Regression guard for the actual reported bug: an earlier fix (an explicit Background
        # on the button row, so gaps between icons are hit-testable) was real but not the whole
        # story - small icons in a thin row, and a tooltip that renders as its own separate
        # floating window rather than part of this row's hit-test area, both make it easy for
        # imprecise mouse movement toward the next icon to dip outside the row for an instant.
        # An instant close on any MouseLeave made that unrecoverable; this grace period doesn't.
        Send-WinUtilMouseLeave -Control $sync.appPopup.Child
        Send-WinUtilMouseEnter -Control $sync.appPopup.Child
        Wait-WinUtilDispatcher -Milliseconds 600

        $sync.appPopup.IsOpen | Should -BeTrue
    }

    It "cancels a stale pending close when the popup is reopened for a different app" {
        # Regression guard for a bug this fix could otherwise introduce: right-clicking a
        # second app while the first popup's close timer is still counting down must not let
        # that stale timer close the NEWLY reopened popup a moment later. Mirrors exactly what
        # Initialize-InstallAppEntry.ps1's own MouseRightButtonUp handler does on open.
        Send-WinUtilMouseLeave -Control $sync.appPopup.Child

        $sync.appPopupCloseTimer.Stop()
        $sync.appPopup.IsOpen = $true

        Wait-WinUtilDispatcher -Milliseconds 600

        $sync.appPopup.IsOpen | Should -BeTrue
    }
}
