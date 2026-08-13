function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        $app = $sync.configs.applicationsHashtable.$appKey

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $app.description
        $border.Add_MouseLeftButtonUp({
            # Resolve through $sync because the border's child is a layout Grid for FOSS entries
            $childCheckbox = $sync.$($this.Tag)
            $childCheckbox.IsChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # The "Open2" icon (a second launch target - e.g. Olivetin's bundled Portainer, or
            # WSL2's own Settings GUI) only exists for the couple of apps that declare
            # "secondaryOpen" - collapsed here rather than left to show a do-nothing icon for
            # every other app. Decided once, per app, right here (not per-hover on the button
            # itself), so the popup's own width is already correct the moment it opens.
            if ($sync.appPopupOpen2Button) {
                $appObject = $sync.configs.applicationsHashtable.$($this.Tag)
                $sync.appPopupOpen2Button.Visibility = if ($appObject.secondaryOpen) {
                    [Windows.Visibility]::Visible
                } else {
                    [Windows.Visibility]::Collapsed
                }
            }
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        # The checkbox sits inside the entry layout Grid, so the border is one level further up
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Tag
            $borderElement = $this.Parent.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Tag
            $borderElement = $this.Parent.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        $contentPanel = New-Object Windows.Controls.StackPanel
        $contentPanel.Orientation = "Horizontal"
        $contentPanel.VerticalAlignment = [Windows.VerticalAlignment]::Center

        $icon = New-Object Windows.Controls.Grid
        $icon.SetResourceReference([Windows.FrameworkElement]::WidthProperty, "AppEntryIconSize")
        $icon.SetResourceReference([Windows.FrameworkElement]::HeightProperty, "AppEntryIconSize")
        $icon.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
        # Needed for "iconScale" below - an oversized Image would otherwise overflow into
        # neighboring tile content instead of being cropped to this slot.
        $icon.ClipToBounds = $true
        $fallback = New-Object Windows.Controls.TextBlock
        $fallback.Text = $app.content.TrimStart(".").Substring(0, 1).ToUpper()
        $fallback.FontWeight = "Bold"; $fallback.HorizontalAlignment = "Center"; $fallback.VerticalAlignment = "Center"
        # Prefer an explicit per-app icon (config/applications.json "icon") over guessing one
        # from the site favicon - the favicon guess only ever finds generic hosting-domain
        # icons (e.g. the GitHub octocat) for the many entries whose "link" points at a repo
        # rather than a dedicated project site.
        $iconUrl = if ($app.icon) { $app.icon } elseif ($app.link) { "https://www.google.com/s2/favicons?sz=64&domain_url=$([uri]::EscapeDataString($app.link))" }
        if ($iconUrl) { $fallback.Visibility = "Collapsed" }
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "AppEntryFontSize")
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ToggleButtonOnColor")
        [void]$icon.Children.Add($fallback)
        if ($iconUrl) {
            $logo = New-Object Windows.Controls.Image
            $logo.Stretch = [Windows.Media.Stretch]::Uniform
            $bitmap = New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = New-Object Uri($iconUrl)
            # Fix the decode size instead of loading at native resolution - keeps this cheap,
            # and for the multi-resolution .ico icons (Feral HTPC, Pluto for Channels, Android
            # ADB Bridge) it tells WPF's icon decoder which embedded frame to pick rather than
            # leaving that to chance.
            $bitmap.DecodePixelWidth = 64
            $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.EndInit()
            $logo.Source = $bitmap

            # Some source icons carry a lot of built-in canvas padding (Windows Store "plate"
            # margins, generous safe-area padding, etc.) that makes them look noticeably
            # smaller than other apps' icons once Uniform-stretched into the same fixed slot.
            # config/applications.json "iconScale" renders the image larger than the slot and
            # lets the icon Grid's clip (above) crop the overflow - zooming past the padding
            # rather than fitting the whole (mostly-empty) canvas.
            $iconScale = if ($app.iconScale) { [double]$app.iconScale } else { 1.0 }
            if ($iconScale -ne 1.0) {
                $baseIconSize = [double]$sync.Form.Resources["AppEntryIconSize"]
                $logo.Width = $baseIconSize * $iconScale
                $logo.Height = $baseIconSize * $iconScale
                $logo.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
                $logo.VerticalAlignment = [Windows.VerticalAlignment]::Center
            }

            $logo.Add_ImageFailed({ $this.Visibility = "Collapsed"; $this.Parent.Children[0].Visibility = "Visible" })
            [void]$icon.Children.Add($logo)
        }
        [void]$contentPanel.Children.Add($icon)

        # Create the TextBlock for the application name - config/applications.json "subtitle"
        # (e.g. Olivetin's "(Includes Portainer)"), when set, becomes a second line in the
        # same white/bold style rather than a separate element, using explicit Inlines/
        # LineBreak since plain .Text doesn't honor embedded newlines. Below that, a second
        # accent-colored TextBlock shows "handle" (the maintainer's CDVR forum handle, e.g.
        # "@bnhf", or an organization name for vendor-made apps). Both are always added, even
        # when an entry has neither, so every tile reserves the same height - conditionally
        # adding them made entries with one taller than every other tile in the grid.
        $nameStack = New-Object Windows.Controls.StackPanel
        $nameStack.Orientation = "Vertical"
        $nameStack.VerticalAlignment = [Windows.VerticalAlignment]::Center

        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        if ($app.subtitle) {
            [void]$appName.Inlines.Add((New-Object Windows.Documents.Run($app.content)))
            [void]$appName.Inlines.Add((New-Object Windows.Documents.LineBreak))
            [void]$appName.Inlines.Add((New-Object Windows.Documents.Run($app.subtitle)))
        } else {
            $appName.Text = $app.content
        }
        [void]$nameStack.Children.Add($appName)

        $appSubtitle = New-Object Windows.Controls.TextBlock
        $appSubtitle.Style = $sync.Form.Resources.AppEntrySubtitleStyle
        $appSubtitle.Text = if ($app.handle) { $app.handle } else { " " }
        [void]$nameStack.Children.Add($appSubtitle)

        [void]$contentPanel.Children.Add($nameStack)
        $checkBox.Content = $contentPanel

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)

        # Keep the same layout for every entry so the checkbox handlers can reach the border
        $entryLayout = New-Object Windows.Controls.Grid
        [void]$entryLayout.Children.Add($checkBox)

        # Mark FOSS apps with a corner badge, bled into the border padding so it sits on the edge
        if ($app.foss -eq $true) {
            $fossBadge = New-WinUtilFossBadge
            $fossBadge.HorizontalAlignment = "Right"
            $fossBadge.VerticalAlignment = "Top"
            $fossBadge.Margin = New-Object Windows.Thickness(0, -4, -6, 0)

            [void]$entryLayout.Children.Add($fossBadge)
        }
        $border.Child = $entryLayout
        if ($sync.selectedApps -contains $appKey) {
            $checkBox.IsChecked = $true
        }
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }
