function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            # An explicit (if invisible) Background is required for the gaps BETWEEN buttons -
            # created by each button's own margin (AppEntryMargin) - to count as "inside" the
            # panel for mouse hit-testing. WPF panels with no Background at all are hit-test
            # transparent in any unpainted area, so without this, MouseLeave fired (closing the
            # whole popup) the instant the mouse crossed from one icon toward the next.
            $appPopupStackPanel.Background = [Windows.Media.Brushes]::Transparent

            # Closing is delayed, not instant, on MouseLeave - confirmed live, the Background
            # fix above (a real, separate bug) wasn't the whole story: these are small icons in
            # a thin row, and naturally imprecise mouse movement toward the next one (or toward
            # reading its tooltip's own text, which renders as a separate floating window, not
            # part of this panel's own hit-test area at all) can still legitimately dip outside
            # the row for an instant. A short grace period - cancelled if the mouse comes back
            # before it elapses - is the same "hover intent" pattern used by virtually every
            # flyout/submenu that has to tolerate imprecise mouse paths between its own items.
            # Stored on $sync (matching $sync.appPopup itself) so the right-click handler that
            # (re)opens this popup - Initialize-InstallAppEntry.ps1 - can cancel a stale pending
            # close: right-clicking a second app within the grace period of the first popup
            # closing would otherwise leave this timer still counting down toward closing the
            # NEWLY reopened popup a moment after it appears.
            $sync.appPopupCloseTimer = New-Object Windows.Threading.DispatcherTimer
            $sync.appPopupCloseTimer.Interval = [TimeSpan]::FromMilliseconds(400)
            $sync.appPopupCloseTimer.Add_Tick({
                $sync.appPopupCloseTimer.Stop()
                $sync.appPopup.IsOpen = $false
            })
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopupCloseTimer.Start()
            })
            $appPopupStackPanel.Add_MouseEnter({
                $sync.appPopupCloseTimer.Stop()
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 },
            [PSCustomObject]@{ Name = "Open";       Icon = [char]0xE8A7 },
            [PSCustomObject]@{ Name = "Open2";      Icon = [char]0xE8A7 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Install or Upgrade $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Uninstall $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Open the application's website in your default browser`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Open-WinUtilLink -Target $appObject.link
                        })
                    }
                    "Open" {
                        # Prefer a known local web interface (config/applications.json "webui")
                        # over guessing - only set for apps with a fixed, documented port. For
                        # everything else, fall back to searching the Start Menu for a matching
                        # shortcut, since community installers run interactively (the user picks
                        # the install location) and winget/choco don't hand back an install path.
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $resolvedWebui = Resolve-WinUtilAppWebUI -AppObject $appObject
                            if ($resolvedWebui) {
                                $this.Tag = $resolvedWebui
                                $this.ToolTip = "Open web interface`n$resolvedWebui"
                            } else {
                                $this.Tag = Find-WinUtilAppLaunchTarget -AppName $appObject.content
                                $this.ToolTip = if ($this.Tag) {
                                    "Launch $($appObject.content)"
                                } else {
                                    "Couldn't find a web interface or installed shortcut for $($appObject.content)"
                                }
                            }
                        })
                        $newButton.Add_Click({
                            if ($this.Tag) {
                                Open-WinUtilLink -Target $this.Tag
                            }
                        })
                    }
                    "Open2" {
                        # A second, optional launch target for the handful of apps that
                        # genuinely have two (config/applications.json "secondaryOpen") - e.g.
                        # Olivetin EZ-Start also bundles Portainer on its own port, and WSL2 has
                        # a native "WSL Settings" GUI app worth surfacing directly. Same shape as
                        # "Open" (a "webui" URL or an appName resolved via
                        # Find-WinUtilAppLaunchTarget), just a second entry rather than the
                        # single implicit one "Open" already covers. Hidden entirely (see the
                        # right-click handler in Initialize-InstallAppEntry.ps1, which sets this
                        # button's Visibility per-app before the popup opens) for the vast
                        # majority of apps that don't declare one, rather than showing a second
                        # icon that does nothing for every other app.
                        $sync.appPopupOpen2Button = $newButton
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $secondary = $appObject.secondaryOpen
                            if ($secondary.webui) {
                                $this.Tag = $secondary.webui
                                $this.ToolTip = "Open $($secondary.label)`n$($secondary.webui)"
                            } elseif ($secondary.appName) {
                                $this.Tag = Find-WinUtilAppLaunchTarget -AppName $secondary.appName
                                $this.ToolTip = if ($this.Tag) {
                                    "Launch $($secondary.label)"
                                } else {
                                    "Couldn't find $($secondary.label) - is it installed?"
                                }
                            }
                        })
                        $newButton.Add_Click({
                            if ($this.Tag) {
                                Open-WinUtilLink -Target $this.Tag
                            }
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}

