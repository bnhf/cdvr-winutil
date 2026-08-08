<#
.NOTES
    CDVR WinUtil - a Channels DVR-focused fork of WinUtil.
    Fork    : https://github.com/bnhf/cdvr-winutil

    Original WinUtil:
    Author         : Chris Titus @christitustech
    Runspace Author: @DeveloperDurp
    GitHub         : https://github.com/ChrisTitusTech
    Version        : 26.08.08
#>

param (
    [string]$Config,
    [ValidateSet("Standard", "Minimal", "Advanced", "")]
    [string]$Preset,
    [switch]$Offline
)

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinUtil is unable to run on your system. PowerShell execution is restricted by security policies." -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WinUtil needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        # Download to a local temp file and elevate via that file, rather than fetching and
        # executing the remote script inline within the elevated command - "download and
        # immediately execute" is a well-known trigger for antivirus/Defender false positives.
        # This also lets $PSCommandPath resolve normally in the elevated instance - matching
        # the winutil-*.ps1 pattern Remove-WinUtilTempScript already expects and cleans up.
        $tempScriptPath = Join-Path ([IO.Path]::GetTempPath()) "winutil-$([guid]::NewGuid().ToString('N')).ps1"
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/bnhf/cdvr-winutil/main/winutil.ps1" -OutFile $tempScriptPath -UseBasicParsing
        "& { & `'$tempScriptPath`' $($argList -join ' ') }"
    }

    # Elevate powershell/pwsh directly rather than wrapping in wt.exe - Windows Terminal's
    # wt.exe is often an MSIX app-execution-alias stub, and UAC elevation via ShellExecute's
    # "runas" verb frequently fails to cross that redirection (error 0x80070005/0x80070002,
    # "error ... when launching '...'" - a known recurring class of issue upstream).
    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Start-Process $powershellCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs

    break
}

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.version = "26.08.08"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.Win11ISOProcessRunning = $false
$sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$winutildir = "$env:LocalAppData\winutil"
$sync.winutildir = $winutildir

$logdir = "$winutildir\logs"
$sync.logPath = "$logdir\winutil_$dateTime.log"
$sync.transcriptPath = $sync.logPath
Start-Transcript -Path $sync.logPath -Append -NoClobber | Out-Null

$Host.UI.RawUI.WindowTitle = "CDVR WinUtil"
Clear-Host
function Add-SelectedAppsMenuItem {
    <#
    .SYNOPSIS
        This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

    .Parameter name
        The actual Name of an App like "Chrome" or "Brave"
        This name is contained in the "Content" property inside the applications.json
    .PARAMETER key
        The key which identifies an app object in applications.json
        For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
    #>

    param ([string]$name, [string]$key)

    $selectedAppGrid = New-Object Windows.Controls.Grid

    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

    # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
    # With the tooltip, you can still read the whole entry on hover
    $selectedAppLabel = New-Object Windows.Controls.Label
    $selectedAppLabel.Content = $name
    $selectedAppLabel.ToolTip = $name
    $selectedAppLabel.HorizontalAlignment = "Left"
    $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
    $selectedAppGrid.Children.Add($selectedAppLabel)

    $selectedAppRemoveButton = New-Object Windows.Controls.Button
    $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
    $selectedAppRemoveButton.Content = [string]([char]0xE711)
    $selectedAppRemoveButton.HorizontalAlignment = "Center"
    $selectedAppRemoveButton.Tag = $key
    $selectedAppRemoveButton.ToolTip = "Remove the App from Selection"
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

    # Highlight the Remove icon on Hover
    $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
    $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
    $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
    })
    [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
    $selectedAppGrid.Children.Add($selectedAppRemoveButton)
    # Add new Element to Popup
    $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
}

function Close-WinUtilRunspacePool {
    if ($null -eq $sync -or -not $sync.ContainsKey("runspace") -or $null -eq $sync.runspace) {
        return
    }

    try {
        if ($sync.runspace.RunspacePoolStateInfo.State -notin @(
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closed,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closing,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Broken
        )) {
            $sync.runspace.Close()
        }
    } finally {
        $sync.runspace.Dispose()
        $sync.Remove("runspace")
    }
}

function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .DESCRIPTION
            Filters application entries by name or description using literal string matching.
            Respects collapsed category state and handles null $sync gracefully.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .PARAMETER Category
            When provided, only applications in this exact category are shown.

        .NOTES
            - Uses module-scope $sync (no parameter needed; inherits from caller's scope)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing hashtable keys and null UI elements
            - Protected by try/catch to prevent UI thread crashes
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = "",

        [Parameter(Mandatory = $false)]
        [string]$Category = ""
    )

    # Validate that $sync exists and has required structure
    if ($null -eq $sync) {
        Write-Warning "Find-AppsByNameOrDescription: Global `$sync not found. Aborting search."
        return
    }

    if ($null -eq $sync.ItemsControl) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.ItemsControl not initialized. Aborting search."
        return
    }

    if ($null -eq $sync.configs -or $null -eq $sync.configs.applicationsHashtable) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.configs.applicationsHashtable not initialized. Aborting search."
        return
    }

    try {
        # Reset the visibility if the search string is empty or the search is cleared
        if ([string]::IsNullOrWhiteSpace($SearchString) -and [string]::IsNullOrWhiteSpace($Category)) {
            $sync.ItemsControl.Items | ForEach-Object {
                # Each item is a StackPanel container
                $_.Visibility = [Windows.Visibility]::Visible

                if ($_.Children.Count -ge 2) {
                    $categoryLabel = $_.Children[0]
                    $wrapPanel = $_.Children[1]

                    # Keep category label visible
                    $categoryLabel.Visibility = [Windows.Visibility]::Visible

                    # Respect the collapsed state of categories (indicated by + prefix)
                    if ($categoryLabel.Content -like "+*") {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                    }
                    else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    }

                    # Show all apps within the category
                    $wrapPanel.Children | ForEach-Object {
                        $_.Visibility = [Windows.Visibility]::Visible
                    }
                }
            }
            return
        }

        # Escape wildcard characters for literal matching
        $escapedSearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

        # Perform search
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]
                $categoryHasMatch = $false

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # Search through apps in this category
                foreach ($appControl in $wrapPanel.Children) {
                    # Safely retrieve app entry from hashtable
                    $appTag = $appControl.Tag
                    $appEntry = $null

                    if (-not [string]::IsNullOrWhiteSpace($appTag) -and $sync.configs.applicationsHashtable.ContainsKey($appTag)) {
                        $appEntry = $sync.configs.applicationsHashtable[$appTag]
                    }

                    # Check if app matches search criteria
                    if ($null -ne $appEntry) {
                        $categoryMatch = -not [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Category -eq $Category
                        $contentMatch = [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Content -like "*$escapedSearchString*"
                        $descriptionMatch = [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Description -like "*$escapedSearchString*"

                        if ($categoryMatch -or $contentMatch -or $descriptionMatch) {
                            # Show the App and mark that this category has a match
                            $appControl.Visibility = [Windows.Visibility]::Visible
                            $categoryHasMatch = $true
                        }
                        else {
                            $appControl.Visibility = [Windows.Visibility]::Collapsed
                        }
                    }
                    else {
                        # Hide app if no entry found (data integrity issue)
                        $appControl.Visibility = [Windows.Visibility]::Collapsed
                    }
                }

                # If category has matches, show the WrapPanel and update the category label to expanded state
                if ($categoryHasMatch) {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    $_.Visibility = [Windows.Visibility]::Visible
                    # Update category label to show expanded state (-)
                    if ($categoryLabel.Content -like "+*") {
                        $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                    }
                }
                else {
                    # Hide the entire category container if no matches
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        Write-Warning "Find-AppsByNameOrDescription: An error occurred during search: $_"
        # Fail gracefully - do not crash the UI thread
        return
    }
}

function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .DESCRIPTION
            Filters tweak entries by name or description using literal string matching (no wildcard expansion).
            Respects collapsed category state and handles null $sync gracefully.
            Safe for rapid keystroke events; no terminal spam on error conditions.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .NOTES
            - Uses module-scope $sync (resolved via global/script fallback if needed)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing UI elements and null properties
            - Protected by try/catch to prevent UI thread crashes
            - PowerShell 5.1 compatible (no ternary operators, no advanced language features)
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = ""
    )

    # ------------------------------------------------------------------------------
    # 1. RESOLVE $SYNC WITH MULTI-LEVEL FALLBACK
    # ------------------------------------------------------------------------------

    if ($null -eq $Sync) {
        $Sync = $global:sync
        if ($null -eq $Sync) {
            $Sync = $script:sync
        }
    }

    # Validate that $Sync exists and has required structure
    if ($null -eq $Sync) {
        # Silent return - function called on every keystroke; no warning spam
        return
    }

    if ($null -eq $Sync.Form) {
        # Silent return - form not yet initialized
        return
    }

    # ------------------------------------------------------------------------------
    # 2. GET REFERENCE TO TWEAKS OR APPX PANEL
    # ------------------------------------------------------------------------------

    $panelName = "tweakspanel"
    if ($null -ne $Sync.currentTab -and $Sync.currentTab -eq "AppX") {
        $panelName = "appxpanel"
    }

    $tweaksPanel = $null
    try {
        $tweaksPanel = $Sync.Form.FindName($panelName)
    }
    catch {
        # Silent return - panel not found or disposed
        return
    }

    if ($null -eq $tweaksPanel) {
        # Silent return - panel doesn't exist
        return
    }

    # ------------------------------------------------------------------------------
    # 3. HANDLE EMPTY/WHITESPACE SEARCH STRING - RESET TO DEFAULT STATE
    # ------------------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        try {
            $tweaksPanel.Children | ForEach-Object {
                $categoryBorder = $_

                # Safely set visibility
                if ($null -ne $categoryBorder) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }

                # Process each category
                if ($categoryBorder -is [Windows.Controls.Border]) {
                    $dockPanel = $null
                    if ($null -ne $categoryBorder.Child) {
                        $dockPanel = $categoryBorder.Child
                    }

                    if ($dockPanel -is [Windows.Controls.DockPanel]) {
                        $itemsControl = $null
                        $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                        if ($null -ne $itemsControl) {
                            # Show all items in the category
                            foreach ($item in $itemsControl.Items) {
                                if ($null -ne $item) {
                                    # Check if it's a category label (first Label in the ItemsControl)
                                    if ($item -is [Windows.Controls.Label]) {
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                    elseif ($item -is [Windows.Controls.DockPanel] -or $item -is [Windows.Controls.StackPanel]) {
                                        # Show all checkbox containers
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            # Silent catch - UI element may be disposed
            $null = $_
        }

        return
    }

    # ------------------------------------------------------------------------------
    # 4. PERFORM LITERAL SEARCH (NO WILDCARD EXPANSION)
    # ------------------------------------------------------------------------------

    try {
        # Normalize search term once for the entire operation
        $searchTerm = $SearchString
        if ($null -eq $searchTerm) {
            $searchTerm = ""
        }

        # Iterate through all categories
        $tweaksPanel.Children | ForEach-Object {
            $categoryBorder = $_
            $categoryHasMatch = $false

            if ($categoryBorder -is [Windows.Controls.Border]) {
                $dockPanel = $null
                if ($null -ne $categoryBorder.Child) {
                    $dockPanel = $categoryBorder.Child
                }

                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $null
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                    if ($null -ne $itemsControl) {
                        $categoryLabel = $null

                        # Process all items (checkboxes, labels, panels) in the ItemsControl
                        for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                            $item = $itemsControl.Items[$i]

                            if ($null -eq $item) {
                                continue
                            }

                            # ------------------------------------------------------------
                            # Check if this is a category label (usually first Label)
                            # ------------------------------------------------------------

                            if ($item -is [Windows.Controls.Label]) {
                                $categoryLabel = $item
                                # Initially hide category label; show it only if matches found
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # ------------------------------------------------------------
                            # Check if this is a DockPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.DockPanel]) {
                                $checkbox = $null
                                $label = $null

                                # Safely extract checkbox and label
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                                $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                                # Check if tweak matches search criteria
                                $itemMatches = $false

                                if ($null -ne $label) {
                                    $labelContent = $label.Content
                                    $labelToolTip = $label.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $labelContent) {
                                        $labelContent = ""
                                    }
                                    if ($null -eq $labelToolTip) {
                                        $labelToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $labelContentStr = [string]$labelContent
                                    $labelToolTipStr = [string]$labelToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $labelContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $labelToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }

                            # ------------------------------------------------------------
                            # Check if this is a StackPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.StackPanel]) {
                                $checkbox = $null
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                                $itemMatches = $false

                                if ($null -ne $checkbox) {
                                    $checkboxContent = $checkbox.Content
                                    $checkboxToolTip = $checkbox.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $checkboxContent) {
                                        $checkboxContent = ""
                                    }
                                    if ($null -eq $checkboxToolTip) {
                                        $checkboxToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $checkboxContentStr = [string]$checkboxContent
                                    $checkboxToolTipStr = [string]$checkboxToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $checkboxContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $checkboxToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }
                        }

                        # ------------------------------------------------------------
                        # Update category label visibility and expanded/collapsed state
                        # ------------------------------------------------------------

                        if ($categoryHasMatch) {
                            # Show category label
                            if ($null -ne $categoryLabel) {
                                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                                # Update category label to expanded state (change "+" to "-")
                                $labelContent = $categoryLabel.Content
                                if ($null -ne $labelContent) {
                                    $labelStr = [string]$labelContent

                                    # Safe string replacement without -replace regex
                                    if ($labelStr.StartsWith("+ ")) {
                                        $expandedLabel = "- " + $labelStr.Substring(2)
                                        $categoryLabel.Content = $expandedLabel
                                    }
                                }
                            }
                        }
                    }
                }

                # ----------------------------------------------------------------
                # Set category border visibility based on whether it has matches
                # ----------------------------------------------------------------

                if ($categoryHasMatch) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }
                else {
                    $categoryBorder.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        # Silent catch - UI elements may be disposed or in unexpected state
        # Do not log to terminal as this function is called on every keystroke
        $null = $_
    }
}

function Find-WinUtilAppLaunchTarget {
    <#
    .SYNOPSIS
        Finds a Start Menu entry matching an app's display name, for launching apps whose
        install location isn't otherwise known.

    .DESCRIPTION
        Community-distributed installers (installType "github") run interactively so the
        user can pick options/location themselves, and winget/choco don't hand back an
        install path either - so this is the only generic way to relaunch an already-
        installed app without hardcoding a path per package.

        Uses Get-StartApps rather than scanning the Programs folder for .lnk files directly,
        since it's the one enumeration that uniformly covers both classic (.lnk-based) and
        MSIX/Store-packaged apps (which have no .lnk file at all - e.g. Windows Terminal only
        shows up here, via its AppID).

        Tries an exact (normalized) name match first, only falling back to a loose bidirectional
        substring match if nothing exact is found - a plain substring match alone is unreliable
        (e.g. app name "Firefox" would arbitrarily match either "Firefox" or the unrelated
        "Firefox Private Browsing" entry depending on enumeration order).

    .OUTPUTS
        A "shell:AppsFolder\<AppID>" path Start-Process can launch directly, or $null if no
        matching Start Menu entry was found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    function Get-NormalizedName([string]$Name) {
        $Name -replace '[^a-zA-Z0-9]', ''
    }

    $normalizedAppName = Get-NormalizedName $AppName
    if ([string]::IsNullOrWhiteSpace($normalizedAppName)) {
        return $null
    }

    $candidates = Get-StartApps | Where-Object { $_.AppID } | ForEach-Object {
        [pscustomobject]@{
            AppID = $_.AppID
            NormalizedName = Get-NormalizedName $_.Name
        }
    }

    $exactMatch = $candidates | Where-Object { $_.NormalizedName -eq $normalizedAppName } | Select-Object -First 1
    if ($exactMatch) {
        return "shell:AppsFolder\$($exactMatch.AppID)"
    }

    # Break ties by closest name length to the target instead of just taking the first match -
    # a plain "first substring match wins" would arbitrarily prefer whichever entry happens to
    # enumerate first (e.g. app name "Chrome" matching unrelated "Chrome Remote Desktop" ahead
    # of the actual "Google Chrome" entry, since both contain "Chrome").
    $looseMatch = $candidates | Where-Object {
        $_.NormalizedName -and (
            $_.NormalizedName -like "*$normalizedAppName*" -or $normalizedAppName -like "*$($_.NormalizedName)*"
        )
    } | Sort-Object { [Math]::Abs($_.NormalizedName.Length - $normalizedAppName.Length) } | Select-Object -First 1
    if ($looseMatch) {
        return "shell:AppsFolder\$($looseMatch.AppID)"
    }

    return $null
}

function Get-WinUtilInstalledAPPX {
    <#

    .SYNOPSIS
        Gets the names of AppX packages installed for all users

    #>

    # AppX module auto-loading can leave PowerShell 7 dependent on a temporary Windows PowerShell
    # compatibility proxy. Run the query in Windows PowerShell 5.1 so it remains available after
    # those temporary proxy files are removed.
    $ps5Command = {
        Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name
    }

    $packageOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($packageOutput | Out-String).Trim()
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to get installed AppX packages: $failureDetails"
        return @()
    }

    return @($packageOutput)
}

function Get-WinUtilPackageLogSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$Preference
    )

    @($Packages | ForEach-Object {
        $package = $_
        $packageName = @($package.Name, $package.Description, $package.winget, $package.choco) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -ne "na" } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace([string]$packageName)) {
            $packageName = "Unknown package"
        }

        if ($Preference -eq "Choco" -and -not [string]::IsNullOrWhiteSpace([string]$package.choco) -and $package.choco -ne "na") {
            "$packageName (choco: $($package.choco))"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$package.winget) -and $package.winget -ne "na") {
            "$packageName (winget: $($package.winget))"
        } else {
            "$packageName (no package id)"
        }
    })
}

function Get-WinUtilPackagesInDependencyOrder {
    <#
    .SYNOPSIS
        Reorders packages so anything another selected package "requires" installs first.

    .DESCRIPTION
        Invoke-WPFInstall.ps1 already runs the WSL2-feature/distro buckets before winget/choco
        as a whole, but packages sharing the SAME bucket (e.g. Docker Desktop and Debian both
        installing via winget now that Debian moved off "wsl --install") had no ordering between
        them - confirmed live: Docker Desktop installed before Debian despite declaring "debian"
        as a requirement, which happened to be harmless this time (Docker Desktop's own install
        doesn't actually need Debian present, only Olivetin - which runs inside Debian - does),
        but is exactly the kind of ordering an actual dependency could break on.

        A topological sort by .Key/.requires, not a hardcoded pairwise check - the catalog
        already has multi-level chains (wsl2 -> debian -> dockerdesktop -> olivetin), and a
        general sort handles any current or future one correctly without needing to special-case
        each pair. Packages without a .Key can't participate in the requires graph (nothing can
        reference them, and their own "requires" can't be resolved against .Key), so they always
        qualify immediately.

        Implemented as repeated passes over the remaining packages (emit anything whose
        in-selection requirements are already placed, repeat until nothing changes), rather than
        recursive-descent through a nested helper function - functionally equivalent, but reads
        more directly as "keep placing whatever's ready" without needing a second function to
        follow. Bounded to at most Packages.Count passes - a dependency cycle (should never
        happen from the catalog itself, but a defensive guard for it regardless) stops making
        progress and whatever's left just gets appended in its original order rather than
        looping forever.

        Returns ,$sorted.ToArray() (leading comma) rather than $sorted.ToArray() - the usual
        reason (PowerShell unwraps a returned empty array to $null across a function-return
        boundary otherwise) plus a corollary worth knowing at every call site: a caller that
        wraps the CALL ITSELF in @(...) - e.g. @(Get-WinUtilPackagesInDependencyOrder ...).Count
        - double-wraps the result, since the comma already makes the array a single pipeline
        object and @() around the call adds another layer. Capture the result in a variable
        first ($result = Get-WinUtilPackagesInDependencyOrder ...), then wrap or measure that
        variable - @() around an already-materialized array variable is idempotent, only @()
        around the call itself is not.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Packages
    )

    $byKey = @{}
    foreach ($p in $Packages) {
        if ($p.Key) { $byKey[[string]$p.Key] = $p }
    }

    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Packages) { $remaining.Add($p) }

    $sorted = [System.Collections.Generic.List[object]]::new()
    $placedKeys = [System.Collections.Generic.HashSet[string]]::new()

    $maxPasses = $remaining.Count
    for ($pass = 0; $pass -lt $maxPasses -and $remaining.Count -gt 0; $pass++) {
        $placedThisPass = [System.Collections.Generic.List[object]]::new()

        foreach ($package in @($remaining)) {
            $unmetRequirement = $false
            foreach ($reqKey in @($package.requires)) {
                $reqKeyString = [string]$reqKey
                if ($byKey.ContainsKey($reqKeyString) -and -not $placedKeys.Contains($reqKeyString)) {
                    $unmetRequirement = $true
                    break
                }
            }

            if (-not $unmetRequirement) {
                $sorted.Add($package)
                if ($package.Key) { [void]$placedKeys.Add([string]$package.Key) }
                $placedThisPass.Add($package)
            }
        }

        if ($placedThisPass.Count -eq 0) { break }
        foreach ($p in $placedThisPass) { [void]$remaining.Remove($p) }
    }

    # Only reached on a genuine dependency cycle - append what's left rather than drop it.
    foreach ($p in $remaining) { $sorted.Add($p) }

    return ,$sorted.ToArray()
}

function Get-WinUtilSelectedPackages {

     param(
         [Parameter(Mandatory = $true)]
         [object] $PackageList,

         [Parameter(Mandatory = $true)]
         [string] $Preference
     )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packagesDirect = [System.Collections.ArrayList]::new()
    $packagesGithub = [System.Collections.ArrayList]::new()
    $packagesNpm = [System.Collections.ArrayList]::new()
    $packagesWslFeature = [System.Collections.ArrayList]::new()
    $packagesWslDistro = [System.Collections.ArrayList]::new()
    $packagesWslCommand = [System.Collections.ArrayList]::new()
    $packagesStreamLinkManager = [System.Collections.ArrayList]::new()
    $packages = @{
        Winget = $packagesWinget
        Choco = $packagesChoco
        Direct = $packagesDirect
        Github = $packagesGithub
        Npm = $packagesNpm
        WslFeature = $packagesWslFeature
        WslDistro = $packagesWslDistro
        WslCommand = $packagesWslCommand
        StreamLinkManager = $packagesStreamLinkManager
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId
        )

        if ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na") {
            return
        }

        if (-not $Target.Contains($PackageId)) {
            $null = $Target.Add($PackageId)
        }
    }

    foreach ($package in $PackageList) {
        $installType = [string]$package.installType

        # Packages with a custom installType bypass the winget/choco preference entirely -
        # they carry their own install data (url, repo, npmPackage, distro, command, ...).
        if (-not [string]::IsNullOrWhiteSpace($installType)) {
            switch ($installType) {
                "direct" { $null = $packagesDirect.Add($package) }
                "github" { $null = $packagesGithub.Add($package) }
                "npm" { $null = $packagesNpm.Add($package) }
                "wslFeature" { $null = $packagesWslFeature.Add($package) }
                "wslDistro" { $null = $packagesWslDistro.Add($package) }
                "wslCommand" { $null = $packagesWslCommand.Add($package) }
                "streamLinkManager" { $null = $packagesStreamLinkManager.Add($package) }
            }
            continue
        }

        switch ($Preference) {
            "Choco" {
                if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget
                } else {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco
                }
            }
            "Winget" {
                Add-PackageId -Target $packagesWinget -PackageId $package.winget
            }
        }
    }

    return $packages
}

Function Get-WinUtilToggleStatus ($ToggleSwitch) {

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    if ($null -eq $sync.ToggleStatusCache) {
        $sync.ToggleStatusCache = @{}
    }

    if ($sync.ToggleStatusCache.ContainsKey($ToggleSwitch)) {
        return [bool]$sync.ToggleStatusCache[$ToggleSwitch]
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
    }

    foreach ($regentry in $ToggleSwitchReg) {

        if (Test-Path $regentry.Path) {
            $regstate = (Get-ItemProperty -Path $regentry.Path).$($regentry.Name)
        } else {
            $regstate = $null
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            $sync.ToggleStatusCache[$ToggleSwitch] = $false
            return $false
        }
    }

    $sync.ToggleStatusCache[$ToggleSwitch] = $true
    return $true
}

function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            }
            catch {
                $null = $_
            }
        }
        return $output
    }
    return $keys
}

    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $Border.Child = $scrollViewer

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        return $itemsControl
    }

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

function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category before creating WPF controls.
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        $sync.InstallAppRenderQueue = [System.Collections.Queue]::new()

        # Categories render in this order; anything not listed falls back to the end, alphabetically.
        $categoryOrder = @("Foundational", "Channels DVR", "Channels DVR Windows Clients", "Channels DVR Sources (non-Docker)")
        $sortedCategories = $appsByCategory.Keys | Sort-Object -Property @(
            @{ Expression = { $index = $categoryOrder.IndexOf($_); if ($index -lt 0) { [int]::MaxValue } else { $index } } },
            @{ Expression = { $_ } }
        )

        foreach ($category in $sortedCategories) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($categoryToggle)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $categoryToggle.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $categoryToggle.Content = $categoryToggle.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $categoryToggle.Content = $categoryToggle.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            $sync.InstallAppRenderQueue.Enqueue([pscustomobject]@{
                Category = $category
                TargetElement = $wrapPanel
                AppKeys = @($appsByCategory[$category] | Sort-Object)
            })
        }

        Start-WinUtilInstallAppRendering
    }

function Initialize-WinUtilRunspacePool {
    if ($sync.runspace -and $sync.runspace.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        return $sync.runspace
    }

    if ($sync.runspace) {
        Close-WinUtilRunspacePool
    }

    # Set the maximum number of threads for the RunspacePool to the number of threads on the machine.
    $maxthreads = [Math]::Max([int]$env:NUMBER_OF_PROCESSORS, 1)

    # Create a new session state for parsing variables into our runspace.
    $hashVars = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null
    $offlineVar = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE', $PARAM_OFFLINE, $null
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $initialSessionState.Variables.Add($hashVars)
    $initialSessionState.Variables.Add($offlineVar)

    # Get every WinUtil/WPF function and add it to the session state.
    $functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
    foreach ($function in $functions) {
        $functionDefinition = Get-Content function:\$($function.Name)
        $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $functionDefinition
        $initialSessionState.Commands.Add($functionEntry)
    }

    $sync.runspace = [runspacefactory]::CreateRunspacePool(
        1,                      # Minimum thread count
        $maxthreads,            # Maximum thread count
        $initialSessionState,   # Initial session state
        $Host                   # Machine to create runspaces on
    )

    $sync.runspace.Open()
    return $sync.runspace
}

function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TabName
    )

    if ($null -eq $sync.InitializedTabs) {
        $sync.InitializedTabs = @{}
    }

    if ($sync.InitializedTabs[$TabName]) {
        return
    }

    switch ($TabName) {
        "Install" {
            Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
            Initialize-WPFUI -targetGridName "appscategory"

            Initialize-WPFUI -targetGridName "appspanel"
        }
        "Tweaks" {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
        }
        "Config" {
            Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2
        }
        "AppX" {
            Invoke-WPFUIElements -configVariable $sync.configs.appx -targetGridName "appxpanel" -columncount 2
        }
        "Win11ISO" {
            if ($sync.Form -and $sync.Form.Dispatcher) {
                $sync.Form.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-WinUtilISOCheckExistingWork }) | Out-Null
            }
        }
    }

    $sync.InitializedTabs[$TabName] = $true
}

function Initialize-WinUtilTaskbarOverlayAssets {
    param(
        [bool]$IncludeLogo = $true,
        [bool]$IncludeStatusAssets = $true
    )

    if ($IncludeLogo -and -not $sync["logorender"]) {
        $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["checkmarkrender"]) {
        $sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["warningrender"]) {
        $sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)
    }
}

function Install-WinUtilAPPX {
    <#

    .SYNOPSIS
        Registers a local AppX package or installs it from the Microsoft Store

    .PARAMETER Name
        The AppX package name to install

    .PARAMETER StoreId
        The optional Microsoft Store product ID used when no local manifest is available

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$StoreId
    )

    Write-WinUtilLog -Component "AppX" -Message "Installing AppX package: $Name"

    # AppX and DISM cmdlets are more reliable in Windows PowerShell 5.1. Query both installed and
    # provisioned package metadata because either can expose a local manifest that can be registered.
    $ps5Command = {
        $packageName = $args[0]
        $manifestPaths = [System.Collections.Generic.List[string]]::new()

        Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -EQ $packageName |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        $manifestPath = $manifestPaths |
            Select-Object -Unique |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if ($null -ne $manifestPath) {
            Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
            Write-Output $manifestPath
        }
    }

    $manifestOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $Name 2>&1
    if ($LASTEXITCODE -eq 0 -and $null -ne $manifestOutput) {
        $manifestPath = ($manifestOutput | Select-Object -Last 1).ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
            Write-WinUtilLog -Component "AppX" -Message "Registered local AppX manifest for $Name`: $manifestPath"
            return
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($manifestOutput | Out-String).Trim()
        Write-WinUtilLog -Level "WARN" -Component "AppX" -Message "Local AppX registration failed for $Name`: $failureDetails"
    }

    if ([string]::IsNullOrWhiteSpace($StoreId)) {
        $errorMessage = "Unable to install $Name because no local manifest or Microsoft Store ID is available."
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "No usable local manifest found for $Name. Installing Microsoft Store product $StoreId."
    Install-WinUtilWinget
    Install-WinUtilProgramWinget -Action Install -Programs @("msstore:$StoreId")
}

function Install-WinUtilChoco {
    if (-not (Get-Command -Name choco)) {
      Write-Host "Chocolatey is not installed. Installing now..."
      $installScript = Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing
      Invoke-Command -ScriptBlock ([scriptblock]::Create($installScript.Content))
    }
}

Function Install-WinUtilFeatureWSL {
    <#
    .SYNOPSIS
        Enables the WSL2 platform feature. First-time enable on many systems requires a
        reboot before WSL is actually usable - this does not claim silent one-click success.

    .DESCRIPTION
        Bounded to several minutes via Invoke-WinUtilWithTimeout, not the few-second default
        used elsewhere for quick DISM/registry checks - "wsl --install" can download the WSL
        kernel/app itself and, on a system where WSL isn't installed yet, can also try to reach
        the Microsoft Store, which can hang for a long time on a slow/absent connection (the
        same real-world quirk Invoke-WinUtilWithTimeout was originally built to guard against
        elsewhere). Verifies success afterward via Test-WinUtilWSLFeatureEnabled rather than
        trusting wsl.exe's own exit behavior - a timeout here isn't necessarily a real failure,
        WSL2 may already be fully enabled underneath it (confirmed live for the sibling distro
        install below: the distro had already finished registering while the wsl.exe call
        itself never returned control to us).
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        Write-WinUtilLog -Component "Package" -Message "Enabling WSL2 ($name)"

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 300 -DefaultValue $null -OnWaitingIntervalSeconds 20 -OnWaiting {
            param($elapsedSeconds)
            Write-WinUtilLog -Component "Package" -Message "Still enabling WSL2 ($($elapsedSeconds)s elapsed) - this can take a while."
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Enabling WSL2 ($($elapsedSeconds)s elapsed)..."
        } -ScriptBlock {
            try {
                return (& wsl --install --no-distribution 2>&1 | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --install --no-distribution did not finish within the expected time - checking whether WSL2 actually enabled anyway."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --install completed with no console output)" })
        }

        # Clears the "uninstalled this session" flag Uninstall-WinUtilFeatureWSL sets, so
        # Test-WinUtilWSLFeatureEnabled goes back to trusting the real DISM/wsl.exe-backed state
        # now that WSL2 has been (re)installed - has to happen before the verification check
        # right below, or that check would still see the stale "uninstalled" flag.
        if ($null -ne $sync) { $sync.WSLRuntimeUninstalled = $false }

        if (Test-WinUtilWSLFeatureEnabled) {
            Write-WinUtilLog -Component "Package" -Message "${name}: WSL2 is enabled and usable."
        } else {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: WSL2 does not appear usable yet - if this is the first time it's been enabled on this machine, a restart is likely required."
        }
    }
}

function Install-WinUtilProgramChoco {
    <#
    .SYNOPSIS
        Installs or uninstalls the given choco package IDs.

    .DESCRIPTION
        Unlike winget, "choco install" is not upgrade-aware - if a package is already present,
        it just reports "already installed" and exits 0 without changing anything, even when a
        newer version is available. So on Install, the requested IDs are first split by current
        install state (one batched "choco list --local-only" call, not one call per package -
        that per-package-call pattern is exactly what caused the earlier DISM-based slowdown
        elsewhere in this app) and already-installed IDs are routed through "choco upgrade"
        instead, so this behaves like winget's install-or-upgrade semantics.

    .OUTPUTS
        One [pscustomobject] per requested program, each with .Program, .Success, and
        .ExitCode - so callers can report real per-item outcomes instead of assuming every
        attempt succeeded. Choco runs one batched command per install/upgrade/uninstall group
        rather than one call per package, so every program in the same batch shares that
        batch's exit code/outcome - the same granularity choco itself gives us.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    $results = [System.Collections.Generic.List[object]]::new()

    if ($Action -eq 'Uninstall') {
        $arguments = "uninstall $Programs -y"
        Write-WinUtilLog -Component "Package" -Message "Uninstall choco package(s): $($Programs -join ', ')"
        $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "Uninstall choco package(s) completed: $($Programs -join ', ')"
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Uninstall choco package(s) FAILED: $($Programs -join ', ') (exit code: $($process.ExitCode))"
        }
        foreach ($program in $Programs) {
            $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
        }
        return ,$results.ToArray()
    }

    $installedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $localList = & choco list --local-only --limit-output 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $localList) {
                # --limit-output gives "id|version" per line, with no header/footer noise to
                # accidentally match against.
                $id = ($line -split '\|')[0].Trim()
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    [void]$installedIds.Add($id)
                }
            }
        }
    } catch {}
    # If the local-package query itself failed, $installedIds stays empty and everything below
    # falls through to "choco install" - the same no-op-if-already-installed behavior as before,
    # not a regression.

    $toInstall = @($Programs | Where-Object { -not $installedIds.Contains($_) })
    $toUpgrade = @($Programs | Where-Object { $installedIds.Contains($_) })

    if ($toInstall.Count -gt 0) {
        $arguments = "install $toInstall -y"
        Write-WinUtilLog -Component "Package" -Message "Install choco package(s): $($toInstall -join ', ')"
        $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "Install choco package(s) completed: $($toInstall -join ', ')"
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Install choco package(s) FAILED: $($toInstall -join ', ') (exit code: $($process.ExitCode))"
        }
        foreach ($program in $toInstall) {
            $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
        }
    }

    if ($toUpgrade.Count -gt 0) {
        $arguments = "upgrade $toUpgrade -y"
        Write-WinUtilLog -Component "Package" -Message "Upgrade already-installed choco package(s): $($toUpgrade -join ', ')"
        $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "Upgrade choco package(s) completed: $($toUpgrade -join ', ')"
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Upgrade choco package(s) FAILED: $($toUpgrade -join ', ') (exit code: $($process.ExitCode))"
        }
        foreach ($program in $toUpgrade) {
            $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
        }
    }

    return ,$results.ToArray()
}

Function Install-WinUtilProgramDirect {
    <#
    .SYNOPSIS
        Downloads and runs an installer from a direct URL - for packages with no winget/choco listing.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $url = $package.url
        $installArgs = $package.args

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Direct install for $name is missing a url."
            continue
        }

        $ext = [IO.Path]::GetExtension($url)
        if ([string]::IsNullOrEmpty($ext)) { $ext = ".exe" }
        $dest = Join-Path $env:TEMP "$name$ext"

        Write-WinUtilLog -Component "Package" -Message "Downloading $name from $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to download ${name}: $_"
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing $name"
        try {
            if ($ext -eq ".msi") {
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$dest`" $installArgs" -Wait
                Write-WinUtilLog -Component "Package" -Message "$name installed."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            } elseif ([string]::IsNullOrWhiteSpace($installArgs)) {
                # No documented silent-install flag, so this runs interactively - and some
                # interactive installers (e.g. Channels DVR Server) launch a long-running
                # application on completion that never exits, which would make -Wait block
                # forever. Launch and move on instead of waiting; don't delete the downloaded
                # file since the process may still be reading it after we return.
                $proc = Start-Process -FilePath $dest -PassThru
                Set-WinUtilProcessForeground -Process $proc
                Write-WinUtilLog -Component "Package" -Message "$name installer launched - it may need you to finish a setup wizard. WinUtil will not wait for it to close."
            } else {
                Start-Process -FilePath $dest -ArgumentList $installArgs -Wait
                Write-WinUtilLog -Component "Package" -Message "$name installed."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run installer for ${name}: $_"
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
    }
}

Function Install-WinUtilProgramGithub {
    <#
    .SYNOPSIS
        Downloads and runs the newest matching release asset from a GitHub repo - for
        Channels DVR community projects not published to winget/choco.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    $headers = @{ "User-Agent" = "cdvr-winutil" }

    foreach ($package in $Packages) {
        $name = $package.content
        $repo = $package.repo
        $assetPattern = $package.assetPattern

        if ([string]::IsNullOrWhiteSpace($repo) -or [string]::IsNullOrWhiteSpace($assetPattern)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "GitHub install for $name is missing repo/assetPattern."
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Querying latest release for $repo"
        $release = $null
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -TimeoutSec 30
        } catch {
            # /releases/latest 404s when the repo's newest release is marked prerelease
            # (e.g. RustDVR's only release, v0.0.1) - fall back to the full release list.
            try {
                $allReleases = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Headers $headers -TimeoutSec 30
                $release = $allReleases | Select-Object -First 1
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to query releases for ${repo}: $_"
                continue
            }
        }

        if (-not $release) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "No releases found for $repo"
            continue
        }

        $asset = $release.assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1
        if (-not $asset) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "No asset matching '$assetPattern' found in latest release of $repo"
            continue
        }

        $dest = Join-Path $env:TEMP $asset.name
        Write-WinUtilLog -Component "Package" -Message "Downloading $($asset.name) for $name"
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing -TimeoutSec 120
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to download ${name}: $_"
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing $name"
        try {
            if ($dest -like "*.msi") {
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$dest`"" -Wait
                Write-WinUtilLog -Component "Package" -Message "$name installed."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            } else {
                # No known silent-install flag for these community-released installers, so this
                # runs interactively - and some interactive installers launch a long-running
                # application on completion that never exits, which would make -Wait block
                # forever. Launch and move on instead of waiting; don't delete the downloaded
                # file since the process may still be reading it after we return.
                $proc = Start-Process -FilePath $dest -PassThru
                Set-WinUtilProcessForeground -Process $proc
                Write-WinUtilLog -Component "Package" -Message "$name installer launched - it may need you to finish a setup wizard. WinUtil will not wait for it to close."
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run installer for ${name}: $_"
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
    }
}

Function Install-WinUtilProgramNpm {
    <#
    .SYNOPSIS
        Installs or uninstalls a global npm package. Requires Node.js/npm to already be on
        PATH - packages using this installType should declare "nodejs" in their "requires".
    #>
    param (
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install",

        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $npmPackage = $package.npmPackage

        if ([string]::IsNullOrWhiteSpace($npmPackage)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm $($Action.ToLower()) for $name is missing npmPackage."
            continue
        }

        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm is not on PATH - can't $($Action.ToLower()) $name."
            continue
        }

        $npmVerb = if ($Action -eq "Uninstall") { "uninstall" } else { "install" }
        Write-WinUtilLog -Component "Package" -Message "$Action $name via npm ($npmPackage)"
        $process = Start-Process -FilePath "npm" -ArgumentList @($npmVerb, "-g", $npmPackage) -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$name npm $($npmVerb) completed (exit code: $($process.ExitCode))"

        # Some npm-distributed tools need a separate step to actually start running (or set up
        # their own auto-start) after the package itself is installed - e.g. Prismcast installs
        # as a dormant CLI until "prismcast service install" registers and starts it as a
        # background service.
        if ($Action -eq "Install" -and $process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($package.postInstallCommand)) {
            Write-WinUtilLog -Component "Package" -Message "Running post-install step for $name`: $($package.postInstallCommand)"
            try {
                & ([scriptblock]::Create($package.postInstallCommand))
                Write-WinUtilLog -Component "Package" -Message "$name post-install step completed"
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Post-install step failed for ${name}: $_"
            }
        }
    }
}

Function Install-WinUtilProgramWinget {
    <#
    .SYNOPSIS
        Installs or uninstalls the given winget package IDs.

    .DESCRIPTION
        Runs winget natively in WinUtil's own (elevated) process first - correct for
        machine-scope packages (e.g. VLC, whose own uninstaller needs admin rights to touch
        Program Files/HKLM). Only retries de-elevated, via Start-WinUtilProcessAsStandardUser,
        when winget's exit code specifically indicates the operation was blocked purely because
        of the wrong integrity context - not on every failure. Blindly de-elevating every winget
        call (an earlier version of this function did that) fixed per-user-scope packages like
        Vivaldi but broke machine-scope ones like VLC, whose bundled uninstaller then failed
        for lack of admin rights - trading one scope-mismatch bug for the opposite one.

    .OUTPUTS
        One [pscustomobject] per attempted program (blank/na entries are skipped, not
        included), each with .Program, .Success, and .ExitCode - so callers can report real
        per-item outcomes instead of assuming every attempt succeeded.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    # winget exit codes that mean "blocked purely by running in the wrong integrity context",
    # not a real install/uninstall failure - safe to retry once in the other context:
    #   0x8A15007D APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED (-1978335107) - a
    #     per-user-scope package refused because WinUtil is running elevated (the Vivaldi case).
    #   0x8A150056 APPINSTALLER_CLI_ERROR_INSTALLER_PROHIBITS_ELEVATION (-1978335146) - the
    #     installer itself refuses to run elevated.
    $wrongContextExitCodes = @(-1978335107, -1978335146)

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $source = "winget"
        if ($program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        if ($Action -eq 'Install') {
            $arguments = @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent")
        } else {
            $arguments = @("uninstall", "--id", $program, "--source", $source, "--silent")
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"

        $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -Wait -PassThru

        if ($wrongContextExitCodes -contains $process.ExitCode) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$Action winget package: $program failed running elevated (exit code: $($process.ExitCode)) - retrying as standard user."
            $process = Start-WinUtilProcessAsStandardUser -FilePath winget -ArgumentList $arguments
        }

        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program"
        } else {
            $hint = if ($Action -eq 'Uninstall') {
                " If this keeps happening, try uninstalling it via Windows Settings > Apps instead."
            } else {
                ""
            }
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action winget package FAILED: $program (exit code: $($process.ExitCode)).$hint"
        }

        $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
    }

    return ,$results.ToArray()
}

Function Install-WinUtilStreamLinkManager {
    <#
    .SYNOPSIS
        Installs Streaming Library Manager natively, without running the upstream slm.bat
        installer.

    .DESCRIPTION
        slm.bat's own "install" command requires an interactive Y/N keypress via the batch
        "choice" builtin, with no documented silent flag - not automatable without piping
        input past the prompt as a workaround. Instead, this replicates slm.bat's underlying
        steps directly (per its source at .../executables/slm.bat): download the same packaged
        Windows release, extract it into a fixed install directory, then register and start it,
        rather than relying on the batch script at all.

        The download itself is a Dropbox link hardcoded in slm.bat - there's no GitHub release
        asset for this app - so this has a real, if unavoidable, dependency on a link the
        project maintainer controls rather than a versioned GitHub artifact.

        No uninstall is documented upstream either. Because this owns the entire install
        location, Uninstall-WinUtilStreamLinkManager can safely remove it outright: stop the
        process, unregister the scheduled task, delete the install directory.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    # Same link slm.bat itself downloads from for a normal (non-prerelease) install.
    $downloadUrl = "https://www.dropbox.com/scl/fi/apw33xi80jjivyjp9rxb4/slm_windows.zip?rlkey=1m5zj7qz9ittguispsi00nyar&dl=1"
    $taskName = "Streaming Library Manager"

    foreach ($package in $Packages) {
        $name = $package.content
        $installDir = Join-Path $env:LocalAppData "StreamLinkManager"
        $zipPath = Join-Path $env:TEMP "slm_windows_$([guid]::NewGuid().ToString('N')).zip"
        $extractPath = Join-Path $env:TEMP "slm_windows_extract_$([guid]::NewGuid().ToString('N'))"

        Write-WinUtilLog -Component "Package" -Message "Installing $name to $installDir"
        try {
            # Stop any running instance first so its files aren't locked during overwrite -
            # slm.bat does the same before it re-extracts over an existing install.
            Get-Process -Name "slm" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

            New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

            Write-WinUtilLog -Component "Package" -Message "Downloading $name"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120

            Write-WinUtilLog -Component "Package" -Message "Extracting $name"
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

            if (-not (Test-Path $installDir)) {
                New-Item -ItemType Directory -Path $installDir -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $extractPath '*') -Destination $installDir -Recurse -Force

            $exePath = Join-Path $installDir "slm.exe"
            if (-not (Test-Path $exePath)) {
                throw "slm.exe not found in the extracted package - the upstream release layout may have changed."
            }

            # Register it to start at logon, matching slm.bat's own "startup" command
            # (schtasks .../rl highest). WinUtil already runs elevated, so - unlike slm.bat,
            # which re-elevates separately for this - the task can be registered directly.
            $runCommand = "powershell -NoProfile -WindowStyle Hidden -Command `"Start-Process -WindowStyle Hidden '$exePath'`""
            & schtasks /create /tn $taskName /tr $runCommand /sc onlogon /rl highest /f | Out-Null

            Write-WinUtilLog -Component "Package" -Message "Starting $name"
            Start-Process -WindowStyle Hidden -FilePath $exePath

            Write-WinUtilLog -Component "Package" -Message "$name installed and started - web interface at $($package.webui)"
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to install ${name}: $_"
        } finally {
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}

Function Install-WinUtilWSLCommand {
    <#
    .SYNOPSIS
        Runs a bash command inside a WSL distro - the install command with {{NAME}} tokens
        substituted from values collected earlier (via Resolve-WinUtilPackagePrompts, on the
        UI thread), or the uninstallCommand as-is when -Action Uninstall.

    .DESCRIPTION
        The command is written to a temp .sh file and placed into the target distro via
        its \\wsl.localhost UNC path, then executed as a script - this avoids the nested
        quoting problems of passing a command with embedded $(...) and quotes through
        `wsl -d <distro> -- bash -c "..."`.

        Written via Set-WinUtilNoBomFileContent, not Set-Content -Encoding UTF8 - see that
        function's own docstring for why: confirmed live, Set-Content's UTF8 encoding prepended
        a byte-order-mark under Windows PowerShell 5.1 (not PowerShell 7+, same command),
        corrupting the first word of the script - a "docker: command not found" error was
        actually a mangled "<BOM>docker", the literal docker install/uninstall command was
        correct, the file it ended up in wasn't.

        If the package declares requiresDockerInDistro, checks that "docker" is actually
        reachable inside the target distro BEFORE running its command, via
        Test-WinUtilDockerAvailableInWSL - Docker Desktop being installed doesn't mean WSL
        integration is enabled for this specific distro, and running the command anyway just
        fails with a generic, deep-in-the-script "command not found" that doesn't point at the
        actual cause. Only meaningful for Install - if docker was reachable when this installed,
        there's no reason to gate uninstall on it too (and doing so would only ever block a
        cleanup step the user is trying to run, for no benefit).

        Checks the wsl.exe call's real exit code rather than assuming success whenever it
        produces any output - confirmed live: a failed docker command (exit code 127, "command
        not found") was still logged as "install completed", because only the ABSENCE of output
        was treated as a problem before, not a non-zero exit code.

        Bounded to several minutes via Invoke-WinUtilWithTimeout, not the few-second default
        used elsewhere for quick DISM/registry checks - these commands can do real work (e.g.
        pulling a Docker image) that legitimately takes a while, and wsl.exe itself can hang for
        unrelated reasons (see Install-WinUtilWSLDistro.ps1 for a confirmed real case). Unlike
        that function, there's no independent way to verify an arbitrary command's success after
        a timeout, so a timeout here is logged as a real, if inconclusive, warning rather than
        silently assumed fine.
    #>
    param (
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install",

        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $distro = $package.distro
        $command = if ($Action -eq "Uninstall") { $package.uninstallCommand } else { $package.command }

        if ([string]::IsNullOrWhiteSpace($distro) -or [string]::IsNullOrWhiteSpace($command)) {
            if ($Action -eq "Uninstall") {
                Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name has no uninstallCommand defined - not uninstalled. Remove it manually if needed."
            } else {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "WSL command install for $name is missing distro/command."
            }
            continue
        }

        if ($Action -eq "Install" -and $package.requiresDockerInDistro) {
            $dockerCheck = Test-WinUtilDockerAvailableInWSL -Distro $distro
            if (-not $dockerCheck.Available) {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Skipping $name install - $($dockerCheck.Reason)"
                continue
            }
        }

        if ($package.PromptValues) {
            foreach ($promptValue in $package.PromptValues.GetEnumerator()) {
                $command = $command.Replace("{{$($promptValue.Key)}}", $promptValue.Value)
            }
        }

        $scriptName = "cdvr-$($package.Key)-$($Action.ToLower()).sh"
        $wslTempPath = "\\wsl.localhost\$distro\tmp\$scriptName"

        Write-WinUtilLog -Component "Package" -Message "Running $name $($Action.ToLower()) inside WSL distro $distro"
        try {
            Set-WinUtilNoBomFileContent -Path $wslTempPath -Value $command

            $result = Invoke-WinUtilWithTimeout -TimeoutSeconds 300 -DefaultValue $null -ArgumentList @($distro, $scriptName) -OnWaitingIntervalSeconds 20 -OnWaiting {
                param($elapsedSeconds)
                Write-WinUtilLog -Component "Package" -Message "Still running $name $($Action.ToLower()) inside WSL ($($elapsedSeconds)s elapsed) - this can take a while."
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Running $name $($Action.ToLower()) ($($elapsedSeconds)s elapsed)..."
            } -ScriptBlock {
                param($distro, $scriptName)
                try {
                    $scriptOutput = (& wsl -d $distro -- bash "/tmp/$scriptName" 2>&1 | Out-String).Trim()
                    return [pscustomobject]@{ Output = $scriptOutput; ExitCode = $LASTEXITCODE }
                } catch {
                    return [pscustomobject]@{ Output = $null; ExitCode = -1 }
                }
            }

            if ($null -eq $result) {
                Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name $($Action.ToLower()) did not finish within the expected time - it may still be running inside WSL, or may need interactive input this app can't provide."
                continue
            }

            Write-WinUtilLog -Component "Package" -Message $(if ($result.Output) { $result.Output } else { "(command completed with no console output)" })
            if ($result.ExitCode -eq 0) {
                Write-WinUtilLog -Component "Package" -Message "$name $($Action.ToLower()) completed."
            } else {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$name $($Action.ToLower()) FAILED (exit code: $($result.ExitCode)) - see the output above for the reason."
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run $($Action.ToLower()) for ${name}: $_"
        } finally {
            Remove-Item -Path $wslTempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Function Install-WinUtilWSLDistro {
    <#
    .SYNOPSIS
        Installs a WSL distro via "wsl --install -d <distro>". Requires the WSL2 feature to
        already be enabled.

    .DESCRIPTION
        No catalog entry currently uses this (installType "wslDistro") - Debian, the original
        user, moved to a normal winget install (Debian.Debian) after the hang described below
        was confirmed to also happen from a genuinely interactive terminal (not just this app's
        background runspace), meaning the install mechanism wasn't actually the cause. Left in
        place rather than removed, in case a future catalog entry needs a distro that isn't
        separately available via winget.

        Bounded to several minutes via Invoke-WinUtilWithTimeout, not the few-second default
        used elsewhere for quick DISM/registry checks - downloading and registering a distro's
        filesystem image genuinely takes a while, and "wsl --install -d <distro>" can hang well
        beyond that: it normally auto-launches the distro afterward for first-run setup (create
        a UNIX username/password), an interactive prompt with no console attached in this app's
        background install runspace. Confirmed live: the distro had already finished
        registering (showed up in "wsl --list") while the install call itself never returned,
        leaving the app looking stalled with no further progress or log output.

        Verifies success afterward via Test-WinUtilWSLDistroInstalled rather than trusting
        wsl.exe's own exit behavior, for the same reason - a timeout here isn't necessarily a
        real failure, the distro may already be fully registered underneath it.

        Logs a periodic "still working" update via -OnWaiting while the install runs - the
        confirmed real case above produced zero console/progress feedback for its full 5-minute
        wait despite genuinely succeeding, which read as a stalled/broken app rather than a
        slow-but-working one.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $distro = $package.distro

        if ([string]::IsNullOrWhiteSpace($distro)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "WSL distro install for $name is missing distro."
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing WSL distro $distro ($name)"

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 300 -DefaultValue $null -ArgumentList @($distro) -OnWaitingIntervalSeconds 20 -OnWaiting {
            param($elapsedSeconds)
            Write-WinUtilLog -Component "Package" -Message "Still installing WSL distro $distro ($($elapsedSeconds)s elapsed) - this can take several minutes, especially on a first install."
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $name ($($elapsedSeconds)s elapsed, this can take several minutes)..."
        } -ScriptBlock {
            param($distro)
            try {
                return (& wsl --install -d $distro 2>&1 | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --install -d $distro did not finish within the expected time - checking whether it actually registered anyway (this is normal if it's waiting on the first-run username prompt, which can't be answered here)."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --install -d $distro completed with no console output)" })
        }

        if (Test-WinUtilWSLDistroInstalled -Distro $distro) {
            Write-WinUtilLog -Component "Package" -Message "$name ($distro) is installed and registered. If this was its first install, launch it once from the Start Menu (not via `"wsl -d $distro`" in an existing terminal - confirmed live to hang waiting on the interactive first-run prompt even there) to finish creating its Linux user account."
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$name ($distro) does not appear to be registered after the install attempt."
        }
    }
}

function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  if ($render -and $null -ne $sync) {
      if ($null -eq $sync.RenderedAssetCache) {
          $sync.RenderedAssetCache = @{}
      }

      $cacheKey = "$(([string]$type).ToLowerInvariant())|$Size"
      if ($sync.RenderedAssetCache.ContainsKey($cacheKey)) {
          return $sync.RenderedAssetCache[$cacheKey]
      }
  }

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoPathData1 = @"
M 18.00,14.00
C 18.00,14.00 45.00,27.74 45.00,27.74
45.00,27.74 57.40,34.63 57.40,34.63
57.40,34.63 59.00,43.00 59.00,43.00
59.00,43.00 59.00,83.00 59.00,83.00
55.35,81.66 46.99,77.79 44.72,74.79
41.17,70.10 42.01,59.80 42.00,54.00
42.00,51.62 42.20,48.29 40.98,46.21
38.34,41.74 25.78,38.60 21.28,33.79
16.81,29.02 18.00,20.20 18.00,14.00 Z
"@
          $LogoPath1 = New-Object Windows.Shapes.Path
          $LogoPath1.Data = [Windows.Media.Geometry]::Parse($LogoPathData1)
          $LogoPath1.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData2 = @"
M 107.00,14.00
C 109.01,19.06 108.93,30.37 104.66,34.21
100.47,37.98 86.38,43.10 84.60,47.21
83.94,48.74 84.01,51.32 84.00,53.00
83.97,57.04 84.46,68.90 83.26,72.00
81.06,77.70 72.54,81.42 67.00,83.00
67.00,83.00 67.00,43.00 67.00,43.00
67.00,43.00 67.99,35.63 67.99,35.63
67.99,35.63 80.00,28.26 80.00,28.26
80.00,28.26 107.00,14.00 107.00,14.00 Z
"@
          $LogoPath2 = New-Object Windows.Shapes.Path
          $LogoPath2.Data = [Windows.Media.Geometry]::Parse($LogoPathData2)
          $LogoPath2.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData3 = @"
M 19.00,46.00
C 21.36,47.14 28.67,50.71 30.01,52.63
31.17,54.30 30.99,57.04 31.00,59.00
31.04,65.41 30.35,72.16 33.56,78.00
38.19,86.45 46.10,89.04 54.00,93.31
56.55,94.69 60.10,97.20 63.00,97.22
65.50,97.24 68.77,95.36 71.00,94.25
76.42,91.55 84.51,87.78 88.82,83.68
94.56,78.20 95.96,70.59 96.00,63.00
96.01,60.24 95.59,54.63 97.02,52.39
98.80,49.60 103.95,47.87 107.00,47.00
107.00,47.00 107.00,67.00 107.00,67.00
106.90,87.69 96.10,93.85 80.00,103.00
76.51,104.98 66.66,110.67 63.00,110.52
60.33,110.41 55.55,107.53 53.00,106.25
46.21,102.83 36.63,98.57 31.04,93.68
16.88,81.28 19.00,62.88 19.00,46.00 Z
"@
          $LogoPath3 = New-Object Windows.Shapes.Path
          $LogoPath3.Data = [Windows.Media.Geometry]::Parse($LogoPathData3)
          $LogoPath3.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a3a4a6")

          $canvas.Children.Add($LogoPath1) | Out-Null
          $canvas.Children.Add($LogoPath2) | Out-Null
          $canvas.Children.Add($LogoPath3) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()
      if ($bitmapImage.CanFreeze) {
          $bitmapImage.Freeze()
      }

      if ($null -ne $sync -and $sync.ContainsKey("RenderedAssetCache")) {
          $sync.RenderedAssetCache[$cacheKey] = $bitmapImage
      }

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}

Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    # "Show Installed Apps" (checkbox "choco"/"winget") calls winget/choco once per app, which
    # is slow enough to be noticeable with no feedback - report per-app progress on the same
    # window-level indicator the install/uninstall workflows use, so it reads the same way.
    if ($CheckBox -eq "choco" -or $checkbox -eq "winget") {
        $appsToCheck = @($sync.configs.applicationsHashtable.GetEnumerator())
        $totalToCheck = $appsToCheck.Count
        $checkedCount = 0
        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Checking installed apps (0/$totalToCheck)" -Percent 0
    }

    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        foreach ($entry in $appsToCheck) {
            $checkedCount++
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Checking $($entry.Value.content) ($checkedCount/$totalToCheck)" -Percent ([int](($checkedCount / $totalToCheck) * 100))
            $packageId = ($entry.Value.choco -split ";")[-1].Trim()
            if ($packageId -ne "na" -and $packageId -in $apps) {
                Write-Output $entry.Key
            }
        }
    }

    if ($checkbox -eq "winget") {
        $originalEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

            # Cheap upfront sanity check so a broken winget (missing, corrupted sources, ...)
            # fails loudly here instead of silently, since the per-app lookups below each
            # swallow their own errors (Test-WinUtilProgramInstalled returns $false on any
            # failure) and would otherwise just look like "nothing is installed".
            $null = winget list --count 1 --accept-source-agreements --disable-interactivity 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "winget list failed with exit code $LASTEXITCODE."
            }

            # Per-app targeted "winget list --id <id> --exact" lookups instead of one bulk
            # "winget list" scanned with a regex: the bulk listing's Id/Source columns are
            # unreliable for apps that self-update outside of winget (e.g. Firefox showed up
            # only as an ARP registry key, with no "Mozilla.Firefox" id/source at all, even
            # though a targeted --id --exact lookup for it resolves correctly).
            foreach ($entry in $appsToCheck) {
                $checkedCount++
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Checking $($entry.Value.content) ($checkedCount/$totalToCheck)" -Percent ([int](($checkedCount / $totalToCheck) * 100))
                $packageId = (($entry.Value.winget -split ";")[-1] -replace "^msstore:", "").Trim()
                if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                    continue
                }
                if (Test-WinUtilProgramInstalled -WingetId $packageId) {
                    Write-Output $entry.Key
                }
            }
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
    }

    # WSL-based entries (wslFeature/wslDistro) carry no winget/choco id at all, so they need
    # their own checks - this runs for either package-manager preference, since $CheckBox is
    # "choco" xor "winget" per call (never both), while WSL detection isn't preference-specific.
    if ($CheckBox -eq "choco" -or $CheckBox -eq "winget") {
        foreach ($entry in $appsToCheck) {
            switch ($entry.Value.installType) {
                "wslFeature" {
                    if (Test-WinUtilWSLFeatureEnabled) { Write-Output $entry.Key }
                }
                "wslDistro" {
                    if ($entry.Value.distro -and (Test-WinUtilWSLDistroInstalled -Distro $entry.Value.distro)) {
                        Write-Output $entry.Key
                    }
                }
            }
        }
        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Finished checking installed apps" -Percent 100
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}

function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}

function Invoke-WinUtilFeatureInstall ($CheckBox) {
    Write-WinUtilLog -Component "Feature" -Message "Applying feature action: $CheckBox"

    if ($sync.configs.feature.$CheckBox.feature) {
        foreach ($feature in $sync.configs.feature.$CheckBox.feature) {
            Write-Host "Installing $feature"
            Write-WinUtilLog -Component "Feature" -Message "Enabling Windows optional feature: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Enabled Windows optional feature: $feature"
        }
    }

    if ($sync.configs.feature.$CheckBox.InvokeScript) {
        foreach ($script in $sync.configs.feature.$CheckBox.InvokeScript) {
            Write-Host "Running Script for $CheckBox"
            Write-WinUtilLog -Component "Feature" -Message "Running feature script for: $CheckBox"
            Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Completed feature script for: $CheckBox"
        }
    }
    Write-WinUtilLog -Component "Feature" -Message "Feature action completed: $CheckBox"
}

function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "AppEntrySubtitleFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "AppEntryNameMaxWidth",
        "AppEntryNameMinHeight",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Store the scale factor so it can be reapplied after theme changes
    $sync.FontScaleFactor = $ScaleFactor

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }
}

function Invoke-WinUtilInstallPSProfile {
    if (-not (Get-Command wt)) {
        Write-Host "Windows Terminal not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.WindowsTerminal --source winget --silent
    }

    if (-not (Get-Command pwsh)) {
        Write-Host "PowerShell 7 not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.PowerShell --source winget --installer-type wix --silent
    }

    wt new-tab pwsh -NoExit -Command "irm https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1 | iex"
}

function Write-WinUtilISOLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $logLine = "[$ts] $Message"
    $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
        $current = $sync["WPFWin11ISOStatusLog"].Text
        if ($current -eq "Ready. Please select a Windows 11 ISO to begin.") {
            $sync["WPFWin11ISOStatusLog"].Text = $logLine
        } else {
            $sync["WPFWin11ISOStatusLog"].Text += "`n$logLine"
        }
        $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
        $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
    })
}

function Invoke-WinUtilISOBrowse {
    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = "Select Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso|All files (*.*)|*.*"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $isoPath    = $dlg.FileName
    $fileSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)

    $sync["WPFWin11ISOPath"].Text           = $isoPath
    $sync["WPFWin11ISOFileInfo"].Text       = "File size: $fileSizeGB GB"
    $sync["WPFWin11ISOFileInfo"].Visibility = "Visible"
    $sync["WPFWin11ISOMountSection"].Visibility       = "Visible"
    $sync["WPFWin11ISOVerifyResultPanel"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility      = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility      = "Collapsed"

    Write-WinUtilISOLog "ISO selected: $isoPath  ($fileSizeGB GB)"
}

function Invoke-WinUtilISOMountAndVerify {
    $isoPath = $sync["WPFWin11ISOPath"].Text

    if ([string]::IsNullOrWhiteSpace($isoPath) -or $isoPath -eq "No ISO selected...") {
        [System.Windows.MessageBox]::Show("Please select an ISO file first.", "No ISO Selected", "OK", "Warning")
        return
    }

    Write-WinUtilISOLog "Mounting ISO: $isoPath"
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Mounting ISO..." -Percent 10
    $sync["WPFWin11ISOBrowseButton"].IsEnabled = $false
    $sync["WPFWin11ISOMountButton"].IsEnabled = $false
    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    Invoke-WPFRunspace -ParameterList @(,('isoPath', $isoPath)) -ScriptBlock {
        param($isoPath)

        try {
            Mount-DiskImage -ImagePath $isoPath

            do {
                Start-Sleep -Milliseconds 500
            } until ((Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter)

            $driveLetter = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter + ":"
            Write-WinUtilISOLog "Mounted at drive $driveLetter"

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Verifying ISO contents..." -Percent 30

            $wimPath = Join-Path $driveLetter "sources\install.wim"
            $esdPath = Join-Path $driveLetter "sources\install.esd"

            if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
                Dismount-DiskImage -ImagePath $isoPath
                Write-WinUtilISOLog "ERROR: install.wim/install.esd not found - not a valid Windows ISO."
                Invoke-WPFUIThread {
                    [System.Windows.MessageBox]::Show(
                        "This does not appear to be a valid Windows ISO.`n`ninstall.wim / install.esd was not found.",
                        "Invalid ISO", "OK", "Error")
                }
                return
            }

            $activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Reading image metadata..." -Percent 55
            $imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName

            if (-not ($imageInfo | Where-Object { $_.ImageName -match "Windows 11" })) {
                Dismount-DiskImage -ImagePath $isoPath
                Write-WinUtilISOLog "ERROR: No 'Windows 11' edition found in the image."
                Invoke-WPFUIThread {
                    [System.Windows.MessageBox]::Show(
                        "No Windows 11 edition was found in this ISO.`n`nOnly official Windows 11 ISOs are supported.",
                        "Not a Windows 11 ISO", "OK", "Error")
                }
                return
            }

            $sync["Win11ISOImageInfo"] = $imageInfo
            $sync["Win11ISODriveLetter"] = $driveLetter
            $sync["Win11ISOWimPath"]     = $activeWim
            $sync["Win11ISOImagePath"]   = $isoPath

            Invoke-WPFUIThread {
                $sync["WPFWin11ISOMountDriveLetter"].Text = "Mounted at: $driveLetter   |   Image file: $(Split-Path $activeWim -Leaf)"
                $sync["WPFWin11ISOEditionComboBox"].Items.Clear()
                foreach ($img in $imageInfo) {
                    [void]$sync["WPFWin11ISOEditionComboBox"].Items.Add("$($img.ImageIndex): $($img.ImageName)")
                }
                if ($sync["WPFWin11ISOEditionComboBox"].Items.Count -gt 0) {
                    $proIndex = -1
                    for ($i = 0; $i -lt $sync["WPFWin11ISOEditionComboBox"].Items.Count; $i++) {
                        if ($sync["WPFWin11ISOEditionComboBox"].Items[$i] -match "Windows 11 Pro(?![\w ])") {
                            $proIndex = $i; break
                        }
                    }
                    $sync["WPFWin11ISOEditionComboBox"].SelectedIndex = if ($proIndex -ge 0) { $proIndex } else { 0 }
                }
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Visible"
                $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
            }

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "ISO verified" -Percent 100
            Write-WinUtilISOLog "ISO verified OK.  Editions found: $($imageInfo.Count)"
        } catch {
            $errorMessage = $_
            Write-WinUtilISOLog "ERROR during mount/verify: $errorMessage"
            Invoke-WPFUIThread {
                [System.Windows.MessageBox]::Show(
                    "An error occurred while mounting or verifying the ISO:`n`n$errorMessage",
                    "Error", "OK", "Error")
            }
        } finally {
            Start-Sleep -Milliseconds 800
            Set-WinUtilTweaksProgressIndicator -Visible $false
            Invoke-WPFUIThread {
                $sync["WPFWin11ISOBrowseButton"].IsEnabled = $true
                $sync["WPFWin11ISOMountButton"].IsEnabled = $true
                $sync["Win11ISOProcessRunning"] = $false
            }
        }
    }
}

function Invoke-WinUtilISOModify {
    $isoPath     = $sync["Win11ISOImagePath"]
    $driveLetter = $sync["Win11ISODriveLetter"]
    $wimPath     = $sync["Win11ISOWimPath"]

    if (-not $isoPath) {
        [System.Windows.MessageBox]::Show(
            "No verified ISO found. Please complete Steps 1 and 2 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    $selectedItem     = $sync["WPFWin11ISOEditionComboBox"].SelectedItem
    $selectedWimIndex = 1
    if ($selectedItem -and $selectedItem -match '^(\d+):') {
        $selectedWimIndex = [int]$Matches[1]
    } elseif ($sync["Win11ISOImageInfo"]) {
        $selectedWimIndex = $sync["Win11ISOImageInfo"][0].ImageIndex
    }
    $selectedEditionName = if ($selectedItem) { ($selectedItem -replace '^\d+:\s*', '') } else { "Unknown" }
    Write-WinUtilISOLog "Selected edition: $selectedEditionName (Index $selectedWimIndex)"

    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOModifying"] = $true
    $sync["Win11ISOProcessRunning"] = $true

    $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path $workDir) {
        $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
    }

    $autounattendContent = if ($WinUtilAutounattendXml) {
        $WinUtilAutounattendXml
    } else {
        $toolsXml = Join-Path $PSScriptRoot "..\..\tools\autounattend.xml"
        if (Test-Path $toolsXml) { Get-Content $toolsXml -Raw } else { "" }
    }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $injectDrivers = $sync["WPFWin11ISOInjectDrivers"].IsChecked -eq $true
    $runspace.SessionStateProxy.SetVariable("sync",                $sync)
    $runspace.SessionStateProxy.SetVariable("isoPath",             $isoPath)
    $runspace.SessionStateProxy.SetVariable("driveLetter",         $driveLetter)
    $runspace.SessionStateProxy.SetVariable("wimPath",             $wimPath)
    $runspace.SessionStateProxy.SetVariable("workDir",             $workDir)
    $runspace.SessionStateProxy.SetVariable("selectedWimIndex",    $selectedWimIndex)
    $runspace.SessionStateProxy.SetVariable("selectedEditionName", $selectedEditionName)
    $runspace.SessionStateProxy.SetVariable("autounattendContent", $autounattendContent)
    $runspace.SessionStateProxy.SetVariable("injectDrivers",       $injectDrivers)

    $isoScriptFuncDef   = "function Invoke-WinUtilISOScript {`n" + ${function:Invoke-WinUtilISOScript}.ToString() + "`n}"
    $win11ISOLogFuncDef = "function Write-WinUtilISOLog {`n"     + ${function:Write-WinUtilISOLog}.ToString()     + "`n}"
    $runspace.SessionStateProxy.SetVariable("isoScriptFuncDef",   $isoScriptFuncDef)
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($isoScriptFuncDef))
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-WinUtilEditionIdFromName {
            param([string]$EditionName)

            $normalizedName = ($EditionName -replace '^Windows\s+11\s+', '').Trim()
            switch -Regex ($normalizedName) {
                '^Home Single Language$'      { return 'CoreSingleLanguage' }
                '^Home N$'                    { return 'CoreN' }
                '^Home$'                      { return 'Core' }
                '^Pro for Workstations N$'    { return 'ProfessionalWorkstationN' }
                '^Pro for Workstations$'      { return 'ProfessionalWorkstation' }
                '^Pro Education N$'           { return 'ProfessionalEducationN' }
                '^Pro Education$'             { return 'ProfessionalEducation' }
                '^Pro N$'                     { return 'ProfessionalN' }
                '^Pro$'                       { return 'Professional' }
                '^Education N$'               { return 'EducationN' }
                '^Education$'                 { return 'Education' }
                '^Enterprise LTSC N$'         { return 'EnterpriseSN' }
                '^Enterprise LTSC$'           { return 'EnterpriseS' }
                '^Enterprise N$'              { return 'EnterpriseN' }
                '^Enterprise$'                { return 'Enterprise' }
                default                       { return '' }
            }
        }

        try {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
            })

            Log "Creating working directory: $workDir"
            $isoContents = Join-Path $workDir "iso_contents"
            New-Item -ItemType Directory -Path $isoContents -Force
            SetProgress "Copying ISO contents..." 10

            Log "Copying ISO contents from $driveLetter to $isoContents..."
            & robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS
            Log "ISO contents copied."
            SetProgress "Preparing setup media..." 25

            $sourceImageFileName = Split-Path $wimPath -Leaf
            $localWim = Join-Path $isoContents "sources\$sourceImageFileName"
            if (-not (Test-Path $localWim)) {
                throw "Copied ISO image file not found: sources\$sourceImageFileName"
            }
            $selectedEditionId = Get-WinUtilEditionIdFromName -EditionName $selectedEditionName

            Log "Writing autounattend.xml and edition selection..."
            Invoke-WinUtilISOScript -ISOContentsDir $isoContents -AutoUnattendXml $autounattendContent -InjectCurrentSystemDrivers $injectDrivers -InstallImagePath $localWim -InstallImageIndex $selectedWimIndex -InstallEditionId $selectedEditionId -Log { param($m) Log $m }

            SetProgress "Preserving install image..." 70
            if ($injectDrivers) {
                Log "Added current-system drivers to $sourceImageFileName index $selectedWimIndex with one mount and commit."
            } else {
                Log "Preserved the original $sourceImageFileName without mounting, exporting, or modifying it."
            }

            SetProgress "Dismounting source ISO..." 80
            Log "Dismounting original ISO..."
            Dismount-DiskImage -ImagePath $isoPath

            $sync["Win11ISOWorkDir"]     = $workDir
            $sync["Win11ISOContentsDir"] = $isoContents

            SetProgress "Modification complete" 100
            Log "install.wim modification complete. Choose an output option in Step 4."

            $sync["WPFWin11ISOOutputSection"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"
            })
        } catch {
            Log "ERROR during modification: $_"

            try {
                $mountedISO = Get-DiskImage -ImagePath $isoPath
                if ($mountedISO -and $mountedISO.Attached) {
                    Log "Cleaning up: dismounting source ISO..."
                    Dismount-DiskImage -ImagePath $isoPath
                }
            } catch { Log "Warning: could not dismount ISO during cleanup: $_" }

            try {
                if (Test-Path $workDir) {
                    Log "Cleaning up: removing temp directory $workDir..."
                    Remove-Item -Path $workDir -Recurse -Force
                }
            } catch { Log "Warning: could not remove temp directory during cleanup: $_" }

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "An error occurred during install.wim modification:`n`n$_",
                    "Modification Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOModifying"] = $false
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
                if ($sync["WPFWin11ISOOutputSection"].Visibility -ne "Visible") {
                    $sync["WPFWin11ISOSelectSection"].Visibility = "Visible"
                    $sync["WPFWin11ISOMountSection"].Visibility  = "Visible"
                    $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                }
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOCheckExistingWork {
    if ($sync["Win11ISOContentsDir"] -and (Test-Path $sync["Win11ISOContentsDir"])) { return }

    # Check if ISO modification is currently in progress
    if ($sync["Win11ISOModifying"]) {
        return
    }

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $existingWorkDir) { return }

    $isoContents = Join-Path $existingWorkDir.FullName "iso_contents"
    if (-not (Test-Path $isoContents)) { return }

    $sync["Win11ISOWorkDir"]     = $existingWorkDir.FullName
    $sync["Win11ISOContentsDir"] = $isoContents

    $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"

    $modified = $existingWorkDir.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
    Write-WinUtilISOLog "Existing working directory found: $($existingWorkDir.FullName)"
    Write-WinUtilISOLog "Last modified: $modified - Skipping Steps 1-3 and resuming at Step 4."
    Write-WinUtilISOLog "Click 'Clean & Reset' if you want to start over with a new ISO."

    [System.Windows.MessageBox]::Show(
        "A previous WinUtil ISO working directory was found:`n`n$($existingWorkDir.FullName)`n`n(Last modified: $modified)`n`nStep 4 (output options) has been restored so you can save the already-modified image.`n`nClick 'Clean & Reset' in Step 4 if you want to start over.",
        "Existing Work Found", "OK", "Info")
}

function Invoke-WinUtilISOCleanAndReset {
    $workDir = $sync["Win11ISOWorkDir"]

    if ($workDir -and (Test-Path $workDir)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "This will delete the temporary working directory:`n`n$workDir`n`nAnd reset the interface back to the start.`n`nContinue?",
            "Clean & Reset", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
    }

    $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",    $sync)
    $runspace.SessionStateProxy.SetVariable("workDir", $workDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            if ($workDir) {
                $mountDir = Join-Path $workDir "wim_mount"
                try {
                    $mountedImages = Get-WindowsImage -Mounted |
                                     Where-Object { $_.Path -like "$workDir*" }
                    if ($mountedImages) {
                        foreach ($img in $mountedImages) {
                            Log "Dismounting WIM at: $($img.Path) (discarding changes)..."
                            SetProgress "Dismounting WIM image..." 3
                            Dismount-WindowsImage -Path $img.Path -Discard
                            Log "WIM dismounted successfully."
                        }
                    } elseif (Test-Path $mountDir) {
                        Log "No mounted WIM reported by Get-WindowsImage. Running DISM /Cleanup-Wim as a precaution..."
                        SetProgress "Running DISM cleanup..." 3
                        & dism /English /Cleanup-Wim | ForEach-Object { Log $_ }
                    }
                } catch {
                    Log "Warning: could not dismount WIM cleanly. Attempting DISM /Cleanup-Wim fallback: $_"
                    try { & dism /English /Cleanup-Wim | ForEach-Object { Log $_ } }
                    catch { Log "Warning: DISM /Cleanup-Wim also failed: $_" }
                }
            }

            if ($workDir -and (Test-Path $workDir)) {
                Log "Scanning files to delete in: $workDir"
                SetProgress "Scanning files..." 5

                $allFiles = @(Get-ChildItem -Path $workDir -File -Recurse -Force)
                $allDirs  = @(Get-ChildItem -Path $workDir -Directory -Recurse -Force |
                    Sort-Object { $_.FullName.Length } -Descending)
                $total   = $allFiles.Count
                $deleted = 0

                Log "Found $total files to delete."

                foreach ($f in $allFiles) {
                    try { Remove-Item -Path $f.FullName -Force } catch { Log "WARNING: could not delete $($f.FullName): $_" }
                    $deleted++
                    if ($deleted % 100 -eq 0 -or $deleted -eq $total) {
                        $pct = [math]::Round(($deleted / [Math]::Max($total, 1)) * 85) + 5
                        SetProgress "Deleting files in $($f.Directory.Name)... ($deleted / $total)" $pct
                    }
                }

                foreach ($d in $allDirs) {
                    try { Remove-Item -Path $d.FullName -Force } catch { Log "WARNING: could not delete $($d.FullName): $_" }
                }

                try { Remove-Item -Path $workDir -Recurse -Force } catch { Log "WARNING: could not delete temp directory ${workDir}: $_" }

                if (Test-Path $workDir) {
                    Log "WARNING: some items could not be deleted in $workDir"
                } else {
                    Log "Temp directory deleted successfully."
                }
            } else {
                Log "No temp directory found - resetting UI."
            }

            SetProgress "Resetting UI..." 95
            Log "Resetting interface..."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["Win11ISOWorkDir"]     = $null
                $sync["Win11ISOContentsDir"] = $null
                $sync["Win11ISOImagePath"]   = $null
                $sync["Win11ISODriveLetter"] = $null
                $sync["Win11ISOWimPath"]     = $null
                $sync["Win11ISOImageInfo"]   = $null
                $sync["Win11ISOUSBDisks"]    = $null

                $sync["WPFWin11ISOPath"].Text                   = "No ISO selected..."
                $sync["WPFWin11ISOFileInfo"].Visibility          = "Collapsed"
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Collapsed"
                $sync["WPFWin11ISOOptionUSB"].Visibility         = "Collapsed"
                $sync["WPFWin11ISOOutputSection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility      = "Collapsed"
                $sync["WPFWin11ISOSelectSection"].Visibility     = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled       = $true
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled   = $true

                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0

                $sync["WPFWin11ISOStatusLog"].Text   = "Ready. Please select a Windows 11 ISO to begin."
            })
        } catch {
            Log "ERROR during Clean & Reset: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $true
            })
        } finally {
            $sync["Win11ISOProcessRunning"] = $false
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOExport {
    $contentsDir = $sync["Win11ISOContentsDir"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show(
            "No modified ISO content found.  Please complete Steps 1-3 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title            = "Save Modified Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso"
    $dlg.FileName         = "Win11_Modified_$(Get-Date -Format 'yyyyMMdd').iso"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $outputISO = $dlg.FileName

    # Locate oscdimg.exe (Windows ADK or winget per-user install)
    $oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "oscdimg.exe" |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) {
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $oscdimg) {
        Write-WinUtilISOLog "oscdimg.exe not found. Attempting to install via winget..."
        try {
            # First ensure winget is installed and operational
            Install-WinUtilWinget

            $winget = Get-Command winget
            $result = & $winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
            Write-WinUtilISOLog "winget output: $result"
            $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                       Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                       Select-Object -First 1 -ExpandProperty FullName
        } catch {
            Write-WinUtilISOLog "winget not available or install failed: $_"
        }

        if (-not $oscdimg) {
            Write-WinUtilISOLog "oscdimg.exe still not found after install attempt."
            [System.Windows.MessageBox]::Show(
                "oscdimg.exe could not be found or installed automatically.`n`nPlease install it manually:`n  winget install -e --id Microsoft.OSCDIMG`n`nOr install the Windows ADK from:`nhttps://learn.microsoft.com/windows-hardware/get-started/adk-install",
                "oscdimg Not Found", "OK", "Warning")
            return
        }
        Write-WinUtilISOLog "oscdimg.exe installed successfully."
    }

    $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)
    $runspace.SessionStateProxy.SetVariable("outputISO",   $outputISO)
    $runspace.SessionStateProxy.SetVariable("oscdimg",     $oscdimg)

    $win11ISOLogFuncDef = "function Write-WinUtilISOLog {`n" + ${function:Write-WinUtilISOLog}.ToString() + "`n}"
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            Write-WinUtilISOLog "Exporting to ISO: $outputISO"
            SetProgress "Building ISO..." 10

            $bootData    = "2#p0,e,b`"$contentsDir\boot\etfsboot.com`"#pEF,e,b`"$contentsDir\efi\microsoft\boot\efisys.bin`""
            $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l`"CTOS_MODIFIED`"", "`"$contentsDir`"", "`"$outputISO`"")

            Write-WinUtilISOLog "Running oscdimg..."

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $oscdimg
            $psi.Arguments              = $oscdimgArgs -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start()

            # Stream stdout line-by-line as oscdimg runs
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-WinUtilISOLog $line }
            }

            $proc.WaitForExit()

            # Flush any stderr after process exits
            $stderr = $proc.StandardError.ReadToEnd()
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-WinUtilISOLog "[stderr]$line" }
            }

            if ($proc.ExitCode -eq 0) {
                SetProgress "ISO exported" 100
                Write-WinUtilISOLog "ISO exported successfully: $outputISO"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show("ISO exported successfully!`n`n$outputISO", "Export Complete", "OK", "Info")
                })
            } else {
                Write-WinUtilISOLog "oscdimg exited with code $($proc.ExitCode)."
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show(
                        "oscdimg exited with code $($proc.ExitCode).`nCheck the status log for details.",
                        "Export Error", "OK", "Error")
                })
            }
        } catch {
            Write-WinUtilISOLog "ERROR during ISO export: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("ISO export failed:`n`n$_", "Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOScript {
    <#
    .SYNOPSIS
        Prepares copied Windows setup media without modifying its install image.

    .DESCRIPTION
        Stages WinUtil's AppX removal, registry tweaks, and scheduled-task cleanup
        in the answer file for first logon, writes sources\ei.cfg for the selected
        edition, and optionally adds current-system drivers to one install.wim index.

    .PARAMETER ISOContentsDir
        Root directory of the copied ISO contents.

    .PARAMETER AutoUnattendXml
        Full XML content for autounattend.xml.

    .PARAMETER InstallEditionId
        Windows setup EditionID for sources\ei.cfg, for example Professional or Core.

    .PARAMETER InstallImagePath
        Copied install.wim to service when current-system driver injection is enabled.

    .PARAMETER InstallImageIndex
        Selected edition index in install.wim.

    .PARAMETER Log
        Optional ScriptBlock for progress/status logging. Receives a single [string] argument.
    #>
    param (
        [Parameter(Mandatory)][string]$ISOContentsDir,
        [string]$AutoUnattendXml = "",
        [bool]$InjectCurrentSystemDrivers = $false,
        [string]$InstallEditionId = "",
        [string]$InstallImagePath = "",
        [int]$InstallImageIndex = 1,
        [scriptblock]$Log = { param($m) Write-Output $m }
    )

    function Add-WinUtilISOStagedDrivers {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [Parameter(Mandatory)][string]$InstallImagePath,
            [Parameter(Mandatory)][int]$InstallImageIndex,
            [scriptblock]$Logger
        )

        function Copy-WinUtilISODriverFolder {
            param (
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Destination
            )

            $folderName = Split-Path $Source -Leaf
            $targetPath = Join-Path $Destination $folderName
            $suffix = 1
            while (Test-Path -LiteralPath $targetPath) {
                $targetPath = Join-Path $Destination "${folderName}_$suffix"
                $suffix++
            }

            Copy-Item -LiteralPath $Source -Destination $targetPath -Recurse -Force -ErrorAction Stop
            return $targetPath
        }

        function Test-WinUtilISOStorageDriver {
            param ([Parameter(Mandatory)][System.IO.FileInfo]$InfFile)

            if ($InfFile.BaseName -match '(?i)(iaahci|iastor|vmd|irst|rst)') {
                return $true
            }

            try {
                return (Get-Content -LiteralPath $InfFile.FullName -Raw -ErrorAction Stop) -match '(?im)^\s*Class\s*=\s*(SCSIAdapter|HDC)\s*(?:;.*)?$'
            } catch {
                & $Logger "Warning: could not classify storage driver '$($InfFile.FullName)': $_"
                return $false
            }
        }

        function Invoke-WinUtilISODism {
            param (
                [Parameter(Mandatory)][string[]]$Arguments,
                [Parameter(Mandatory)][string]$Operation
            )

            $output = @(& dism.exe @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                foreach ($line in @($output | Select-Object -Last 20)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                        & $Logger "  dism[$Operation]: $line"
                    }
                }
                throw "DISM $Operation failed with exit code $exitCode."
            }
            if ($Operation -ne 'metadata') {
                & $Logger "DISM $Operation completed."
            }
            return $output
        }

        function Get-WinUtilISOWimMetadata {
            param ([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][int]$Index)

            $metadata = @{}
            $output = Invoke-WinUtilISODism -Arguments @('/English', '/Get-WimInfo', "/WimFile:$ImagePath", "/Index:$Index") -Operation 'metadata'
            foreach ($line in $output) {
                if ([string]$line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
                    $metadata[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
            return $metadata
        }

        function Assert-WinUtilISOWimMetadata {
            param (
                [Parameter(Mandatory)][hashtable]$Before,
                [hashtable]$After
            )

            foreach ($key in 'Languages', 'Installation', 'Edition', 'ProductSuite', 'ProductType') {
                $beforeValue = [string]$Before[$key]
                if ($beforeValue -eq '<undefined>' -or ($key -in 'Installation', 'Edition', 'ProductType' -and [string]::IsNullOrWhiteSpace($beforeValue))) {
                    throw "install.wim metadata is already invalid: $key is undefined. Driver injection was not attempted."
                }
                if ($After) {
                    $afterValue = [string]$After[$key]
                    if ($afterValue -eq '<undefined>' -or ($beforeValue -and $afterValue -ne $beforeValue)) {
                        throw "install.wim metadata validation failed after driver injection: $key changed from '$beforeValue' to '$afterValue'."
                    }
                }
            }
        }

        function Test-WinUtilISOMountedImage {
            param ([Parameter(Mandatory)][string]$Path)

            return @(& dism.exe /English /Get-MountedImageInfo 2>$null) -match [regex]::Escape($Path)
        }

        if ([IO.Path]::GetExtension($InstallImagePath) -ne '.wim') {
            throw 'Current-system driver injection requires install.wim; install.esd cannot be serviced in place.'
        }
        if (-not (Test-Path -LiteralPath $InstallImagePath)) {
            throw "install.wim was not found: $InstallImagePath"
        }
        if ($InstallImageIndex -lt 1) {
            throw 'Current-system driver injection requires a valid install.wim image index.'
        }

        $driverExportRoot = Join-Path $env:TEMP "WinUtil_DriverExport_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
        $mountDir = Join-Path (Split-Path -Path $ContentRoot -Parent) 'wim_mount'
        New-Item -Path $driverExportRoot -ItemType Directory -Force | Out-Null
        $imageMounted = $false

        try {
            & $Logger "Exporting current system drivers before modifying install.wim..."
            $dismLog = Join-Path $env:TEMP "WinUtil_DismDriverExport_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            $dismProcess = Start-Process -FilePath "dism.exe" -ArgumentList "/online /export-driver /destination:`"$driverExportRoot`" /LogPath:`"$dismLog`"" -Wait -NoNewWindow -PassThru
            if ($dismProcess.ExitCode -ne 0) {
                throw "dism.exe driver export failed with exit code $($dismProcess.ExitCode)."
            }

            $driverInfs = @(Get-ChildItem -Path $driverExportRoot -Filter '*.inf' -Recurse -File)
            if ($driverInfs.Count -eq 0) {
                throw 'DISM exported no driver INF files.'
            }
            $driverFolders = @($driverInfs | Group-Object { $_.Directory.FullName })
            $winpeDriverDir = Join-Path $ContentRoot '$WinpeDriver$'
            $storageCount = 0
            $copyFailures = 0

            foreach ($driverFolderGroup in $driverFolders) {
                $driverFolder = [string]$driverFolderGroup.Name
                $storageInfs = @($driverFolderGroup.Group | Where-Object { Test-WinUtilISOStorageDriver -InfFile $_ })
                if ($storageInfs.Count -eq 0) {
                    continue
                }

                try {
                    New-Item -Path $winpeDriverDir -ItemType Directory -Force | Out-Null
                    $winpeTarget = Copy-WinUtilISODriverFolder -Source $driverFolder -Destination $winpeDriverDir
                    $storageCount++
                    & $Logger "Staged boot-storage package '$driverFolder' for WinPE as '$winpeTarget'."
                } catch {
                    $copyFailures++
                    & $Logger "Warning: failed to stage boot-storage package '$driverFolder': $_"
                }
            }

            if ($copyFailures -gt 0) {
                throw "Failed to stage $copyFailures boot-storage driver package folders."
            }

            & $Logger "Exported $($driverInfs.Count) driver INF files across $($driverFolders.Count) package folders; staged $storageCount boot-storage packages for WinPE."
            $metadataBefore = Get-WinUtilISOWimMetadata -ImagePath $InstallImagePath -Index $InstallImageIndex
            Assert-WinUtilISOWimMetadata -Before $metadataBefore

            Set-ItemProperty -LiteralPath $InstallImagePath -Name IsReadOnly -Value $false
            New-Item -Path $mountDir -ItemType Directory -Force | Out-Null
            & $Logger "Mounting install.wim index $InstallImageIndex once for driver injection..."
            Invoke-WinUtilISODism -Arguments @('/English', '/Mount-Image', "/ImageFile:$InstallImagePath", "/Index:$InstallImageIndex", "/MountDir:$mountDir") -Operation 'mount' | Out-Null
            $imageMounted = $true

            & $Logger "Adding all exported drivers to the selected Windows image in one DISM operation..."
            Invoke-WinUtilISODism -Arguments @('/English', "/Image:$mountDir", '/Add-Driver', "/Driver:$driverExportRoot", '/Recurse') -Operation 'add-driver' | Out-Null

            & $Logger 'Committing the driver-only install.wim change...'
            Invoke-WinUtilISODism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Commit') -Operation 'commit' | Out-Null
            $imageMounted = $false

            $metadataAfter = Get-WinUtilISOWimMetadata -ImagePath $InstallImagePath -Index $InstallImageIndex
            Assert-WinUtilISOWimMetadata -Before $metadataBefore -After $metadataAfter
            & $Logger 'Driver injection complete; install.wim metadata validation passed.'
        } finally {
            if ($imageMounted -or (Test-WinUtilISOMountedImage -Path $mountDir)) {
                try {
                    Invoke-WinUtilISODism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Discard') -Operation 'discard' | Out-Null
                } catch {
                    & $Logger "Warning: could not discard the failed install.wim mount: $_"
                }
            }
            Remove-Item -Path $mountDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $driverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Write-WinUtilISOEditionConfig {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [string]$EditionId,
            [scriptblock]$Logger
        )

        $sourcesDir = Join-Path $ContentRoot "sources"
        New-Item -Path $sourcesDir -ItemType Directory -Force | Out-Null

        $pidPath = Join-Path $sourcesDir "PID.txt"
        if (Test-Path $pidPath) {
            Remove-Item -Path $pidPath -Force
            & $Logger "Removed sources\PID.txt so setup will not force a stale or mismatched product key."
        }

        if ([string]::IsNullOrWhiteSpace($EditionId)) {
            & $Logger "Warning: selected edition ID is unknown - skipping sources\ei.cfg fallback."
            return
        }

        $eiCfgPath = Join-Path $sourcesDir "ei.cfg"
        $eiCfg = @"
[EditionID]
$EditionId
[Channel]
Retail
[VL]
0
"@.Trim()

        Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
        & $Logger "Written sources\ei.cfg for EditionID '$EditionId'."
    }

    function Add-WinUtilISOSetupCustomizations {
        param (
            [Parameter(Mandatory)][string]$XmlContent,
            [Parameter(Mandatory)][int]$InstallImageIndex,
            [scriptblock]$Logger
        )

        $appxPackages = @(
            'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingSearch',
            'Microsoft.BingWeather', 'Microsoft.GetHelp', 'Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftStickyNotes',
            'Microsoft.OutlookForWindows', 'Microsoft.Paint', 'Microsoft.PowerAutomateDesktop',
            'Microsoft.StartExperiencesApp', 'Microsoft.Todos', 'Microsoft.Windows.DevHome',
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsSoundRecorder',
            'Microsoft.ZuneMusic', 'MicrosoftCorporationII.QuickAssist', 'MSTeams'
        )

        $appxList = ($appxPackages | ForEach-Object { "    '$_'" }) -join "`r`n"
        $postInstallScript = @"
`$ErrorActionPreference = 'Continue'
`$logPath = 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.log'
Start-Transcript -Path `$logPath -Append -ErrorAction SilentlyContinue

try {
    Write-Host 'WinUtil: Removing provisioned AppX packages...'
    `$packages = @(
$appxList
    )
    foreach (`$package in `$packages) {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { `$_.DisplayName -like "*`$package*" } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { `$_.Name -like "*`$package*" } |
            ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue | Out-Null }
    }

    function Set-WinUtilRegistryValue([string]`$Path, [string]`$Name, [string]`$Type, [string]`$Value) {
        reg.exe add `$Path /v `$Name /t `$Type /d `$Value /f 2>&1 | Out-Null
    }

    function Set-WinUtilContentDeliveryManagerValues([string]`$HiveRoot) {
        `$contentDeliveryManager = "`$HiveRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Set-WinUtilRegistryValue `$contentDeliveryManager 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'ContentDeliveryAllowed' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'FeatureManagementEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SoftLandingEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContentEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
        reg.exe delete "`$contentDeliveryManager\Subscriptions" /f 2>&1 | Out-Null
        reg.exe delete "`$contentDeliveryManager\SuggestedApps" /f 2>&1 | Out-Null
    }

    Write-Host 'WinUtil: Applying registry tweaks...'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' /f 2>&1 | Out-Null
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' /f 2>&1 | Out-Null
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer' 'REG_SZ' 'http://localhost:8080'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUStatusServer' 'REG_SZ' 'http://localhost:8080'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' 'workCompleted' 'REG_DWORD' '1'
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' /f 2>&1 | Out-Null
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\BITS' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' 'Start' 'REG_DWORD' '4'

    `$defaultHive = 'HKU\WinUtilDefault'
    reg.exe load `$defaultHive 'C:\Users\Default\NTUSER.DAT' 2>&1 | Out-Null
    if (`$LASTEXITCODE -eq 0) {
        Set-WinUtilRegistryValue "`$defaultHive\Control Panel\UnsupportedHardwareNotificationCache" 'SV1' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Control Panel\UnsupportedHardwareNotificationCache" 'SV2' 'REG_DWORD' '0'
        Set-WinUtilContentDeliveryManagerValues `$defaultHive
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" 'HasAccepted' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Input\TIPC" 'Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization\TrainedDataStore" 'HarvestContacts' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Personalization\Settings" 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
        reg.exe unload `$defaultHive 2>&1 | Out-Null
    }

    Set-WinUtilContentDeliveryManagerValues 'HKCU'
    Set-WinUtilRegistryValue 'HKCU\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'

    Write-Host 'WinUtil: Removing scheduled task definitions...'
    `$taskPaths = @(
        'C:\Windows\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Chkdsk\Proxy',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        'C:\Windows\System32\Tasks\Microsoft\Windows\InstallService',
        'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateOrchestrator',
        'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateAssistant',
        'C:\Windows\System32\Tasks\Microsoft\Windows\WaaSMedic',
        'C:\Windows\System32\Tasks\Microsoft\Windows\WindowsUpdate',
        'C:\Windows\System32\Tasks\Microsoft\WindowsUpdate'
    )
    foreach (`$taskPath in `$taskPaths) { Remove-Item -LiteralPath `$taskPath -Recurse -Force -ErrorAction SilentlyContinue }

    Start-Process -FilePath 'C:\Windows\System32\OneDriveSetup.exe' -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue
    Write-Host 'WinUtil: Post-install customization complete.'
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
"@

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')

        $setupComponent = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]', $nsMgr)
        $extensions = $xmlDoc.SelectSingleNode('//sg:Extensions', $nsMgr)
        $firstLogonFile = $xmlDoc.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\FirstLogon.ps1"]', $nsMgr)
        if (-not $setupComponent -or -not $extensions -or -not $firstLogonFile) {
            throw 'autounattend.xml is missing a required Windows Setup, Extensions, or FirstLogon.ps1 node.'
        }

        $imageInstall = $setupComponent.SelectSingleNode('u:ImageInstall', $nsMgr)
        if (-not $imageInstall) {
            $imageInstall = $xmlDoc.CreateElement('ImageInstall', $setupComponent.NamespaceURI)
            [void]$setupComponent.AppendChild($imageInstall)
        }
        $osImage = $imageInstall.SelectSingleNode('u:OSImage', $nsMgr)
        if (-not $osImage) {
            $osImage = $xmlDoc.CreateElement('OSImage', $setupComponent.NamespaceURI)
            [void]$imageInstall.AppendChild($osImage)
        }
        $installFrom = $osImage.SelectSingleNode('u:InstallFrom', $nsMgr)
        if (-not $installFrom) {
            $installFrom = $xmlDoc.CreateElement('InstallFrom', $setupComponent.NamespaceURI)
            [void]$osImage.AppendChild($installFrom)
        }
        foreach ($existingMetadata in @($installFrom.SelectNodes('u:MetaData', $nsMgr))) {
            [void]$installFrom.RemoveChild($existingMetadata)
        }
        $metadata = $xmlDoc.CreateElement('MetaData', $setupComponent.NamespaceURI)
        $action = $xmlDoc.CreateAttribute('wcm', 'action', 'http://schemas.microsoft.com/WMIConfig/2002/State')
        $action.Value = 'add'
        [void]$metadata.Attributes.Append($action)
        $key = $xmlDoc.CreateElement('Key', $setupComponent.NamespaceURI)
        $key.InnerText = '/IMAGE/INDEX'
        [void]$metadata.AppendChild($key)
        $value = $xmlDoc.CreateElement('Value', $setupComponent.NamespaceURI)
        $value.InnerText = [string]$InstallImageIndex
        [void]$metadata.AppendChild($value)
        [void]$installFrom.AppendChild($metadata)

        $postInstallFile = $xmlDoc.CreateElement('File', $extensions.NamespaceURI)
        $postInstallFile.SetAttribute('path', 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.ps1')
        $postInstallFile.InnerText = $postInstallScript
        [void]$extensions.AppendChild($postInstallFile)

        $firstLogonFile.InnerText = "& 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.ps1';`r`n`r`n$($firstLogonFile.InnerText.Trim())"

        $null = & $Logger 'Added WinUtil post-install AppX, registry, and scheduled-task customizations to autounattend.xml.'
        return $xmlDoc.OuterXml
    }

    function Add-WinUtilISOSetupScriptFallback {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [Parameter(Mandatory)][string]$XmlContent,
            [scriptblock]$Logger
        )

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')

        $setupScriptsRoot = Join-Path $ContentRoot 'sources\$OEM$\$$\Setup\Scripts'
        $stagedCount = 0
        foreach ($file in $xmlDoc.SelectNodes('//sg:File', $nsMgr)) {
            $path = $file.GetAttribute('path')
            if (-not $path.StartsWith('C:\Windows\Setup\Scripts\', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $relativePath = $path.Substring('C:\Windows\Setup\Scripts\'.Length)
            $targetPath = Join-Path $setupScriptsRoot $relativePath
            New-Item -Path (Split-Path $targetPath -Parent) -ItemType Directory -Force | Out-Null

            $encoding = switch ([System.IO.Path]::GetExtension($targetPath)) {
                { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; break }
                { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true); break }
                default { [System.Text.Encoding]::Default }
            }
            $bytes = $encoding.GetPreamble() + $encoding.GetBytes($file.InnerText.Trim())
            [System.IO.File]::WriteAllBytes($targetPath, $bytes)
            $stagedCount++
        }

        $useConfigurationSet = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]/u:UseConfigurationSet', $nsMgr)
        if ($useConfigurationSet) {
            $useConfigurationSet.InnerText = 'true'
            [System.IO.File]::WriteAllText((Join-Path $ContentRoot 'autounattend.xml'), $xmlDoc.OuterXml, [System.Text.UTF8Encoding]::new($false))
        }
        & $Logger "Staged $stagedCount WinUtil setup script fallback files at '$setupScriptsRoot'."
    }

    if (-not (Test-Path $ISOContentsDir)) {
        throw "ISO contents directory does not exist: $ISOContentsDir"
    }

    if ([string]::IsNullOrWhiteSpace($AutoUnattendXml)) {
        throw "autounattend.xml content is required to prepare setup media."
    }

    $preparedAutoUnattendXml = Add-WinUtilISOSetupCustomizations -XmlContent $AutoUnattendXml -InstallImageIndex $InstallImageIndex -Logger $Log
    $unattendPath = Join-Path $ISOContentsDir "autounattend.xml"
    [System.IO.File]::WriteAllText($unattendPath, $preparedAutoUnattendXml, [System.Text.UTF8Encoding]::new($false))
    & $Log "Written autounattend.xml with WinUtil setup customizations to ISO root ($unattendPath)."
    Add-WinUtilISOSetupScriptFallback -ContentRoot $ISOContentsDir -XmlContent $preparedAutoUnattendXml -Logger $Log

    Write-WinUtilISOEditionConfig -ContentRoot $ISOContentsDir -EditionId $InstallEditionId -Logger $Log

    if ($InjectCurrentSystemDrivers) {
        Add-WinUtilISOStagedDrivers -ContentRoot $ISOContentsDir -Logger $Log -InstallImagePath $InstallImagePath -InstallImageIndex $InstallImageIndex
    }
}

function Invoke-WinUtilISORefreshUSBDrives {
    $combo    = $sync["WPFWin11ISOUSBDriveComboBox"]
    $removable = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)

    $combo.Items.Clear()

    if ($removable.Count -eq 0) {
        $combo.Items.Add("No USB drives detected.")
        $combo.SelectedIndex = 0
        $sync["Win11ISOUSBDisks"] = @()
        Write-WinUtilISOLog "No USB drives detected."
        return
    }

    foreach ($disk in $removable) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $combo.Items.Add("Disk $($disk.Number): $($disk.FriendlyName)  [$sizeGB GB] - $($disk.PartitionStyle)")
    }
    $combo.SelectedIndex = 0
    Write-WinUtilISOLog "Found $($removable.Count) USB drive(s)."
    $sync["Win11ISOUSBDisks"] = $removable
}

function Invoke-WinUtilISOWriteUSB {
    $contentsDir = $sync["Win11ISOContentsDir"]
    $usbDisks    = $sync["Win11ISOUSBDisks"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show("No modified ISO content found. Please complete Steps 1-3 first.", "Not Ready", "OK", "Warning")
        return
    }

    $installWim = Join-Path $contentsDir "sources\install.wim"
    $installEsd = Join-Path $contentsDir "sources\install.esd"
    if (Test-Path $installEsd) {
        $installEsdFile = Get-Item $installEsd
        $esdSizeBytes = $installEsdFile.Length
        $esdSizeMB = [math]::Ceiling($esdSizeBytes / 1MB)
        if ($esdSizeBytes -ge 4GB) {
            [System.Windows.MessageBox]::Show(
                "This ISO uses an install.esd file that is $esdSizeMB MB. WinUtil's FAT32 USB format cannot store files larger than 4 GB.`n`nExport an ISO instead or use media with install.wim.",
                "USB Creation Not Supported", "OK", "Warning")
            return
        }
    }

    $combo = $sync["WPFWin11ISOUSBDriveComboBox"]
    $selectedIndex = $combo.SelectedIndex
    $selectedItemText = [string]$combo.SelectedItem
    $usbDisks = @($usbDisks)

    $targetDisk = $null
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $usbDisks.Count) {
        $targetDisk = $usbDisks[$selectedIndex]
    } elseif ($selectedItemText -match 'Disk\s+(\d+):') {
        $selectedDiskNum = [int]$matches[1]
        $targetDisk = $usbDisks | Where-Object { $_.Number -eq $selectedDiskNum } | Select-Object -First 1
    }

    if (-not $targetDisk) {
        [System.Windows.MessageBox]::Show("Please select a USB drive from the dropdown.", "No Drive Selected", "OK", "Warning")
        return
    }

    $diskNum    = $targetDisk.Number
    $sizeGB     = [math]::Round($targetDisk.Size / 1GB, 1)

    $confirm = [System.Windows.MessageBox]::Show(
        "ALL data on Disk $diskNum ($($targetDisk.FriendlyName), $sizeGB GB) will be PERMANENTLY ERASED.`n`nAre you sure you want to continue?",
        "Confirm USB Erase", "YesNo", "Warning")

    if ($confirm -ne "Yes") {
        Write-WinUtilISOLog "USB write cancelled by user."
        return
    }

    $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true
    Write-WinUtilISOLog "Starting USB write to Disk $diskNum..."

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("diskNum",     $diskNum)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-FreeDriveLetter {
            $used = (Get-PSDrive -PSProvider FileSystem).Name
            foreach ($c in [char[]](68..90)) {
                if ($used -notcontains [string]$c) { return $c }
            }
            return $null
        }

        try {
            SetProgress "Formatting USB drive..." 10

            # Phase 1: Clean disk via diskpart (retry once if the drive is not yet ready)
            $dpFile1 = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
            "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1 -Encoding ASCII
            Log "Running diskpart clean on Disk $diskNum..."
            $dpCleanOut = diskpart /s $dpFile1
            $dpCleanOut | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile1 -Force

            if (($dpCleanOut -join ' ') -match 'device is not ready') {
                Log "Disk $diskNum was not ready; waiting 5 seconds and retrying clean..."
                Start-Sleep -Seconds 5
                Update-Disk -Number $diskNum
                $dpFile1b = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
                "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1b -Encoding ASCII
                diskpart /s $dpFile1b | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
                Remove-Item $dpFile1b -Force
            }

            # Phase 2: Initialize as GPT
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum
            $diskObj = Get-Disk -Number $diskNum
            if ($diskObj.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum initialized as GPT."
            } else {
                Set-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum converted to GPT (was $($diskObj.PartitionStyle))."
            }

            # Phase 3: Create FAT32 partition via diskpart, then format with Format-Volume
            # (diskpart's 'format' command can fail with "no volume selected" on fresh/never-formatted drives)
            $volLabel = "W11-" + (Get-Date).ToString('yyMMdd')
            $dpFile2  = Join-Path $env:TEMP "winutil_diskpart2_$(Get-Random).txt"
            $maxFat32PartitionMB = 32768
            $diskSizeMB = [int][Math]::Floor((Get-Disk -Number $diskNum).Size / 1MB)
            $createPartitionCommand = "create partition primary"
            if ($diskSizeMB -gt $maxFat32PartitionMB) {
                $createPartitionCommand = "create partition primary size=$maxFat32PartitionMB"
                Log "Disk $diskNum is $diskSizeMB MB; creating FAT32 partition capped at $maxFat32PartitionMB MB (32 GB)."
            }

            @(
                "select disk $diskNum"
                $createPartitionCommand
                "exit"
            ) | Set-Content -Path $dpFile2 -Encoding ASCII
            Log "Creating partitions on Disk $diskNum..."
            diskpart /s $dpFile2 | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile2 -Force

            SetProgress "Formatting USB partition..." 25
            Start-Sleep -Seconds 3
            Update-Disk -Number $diskNum

            $partitions = Get-Partition -DiskNumber $diskNum
            Log "Partitions on Disk $diskNum after creation: $($partitions.Count)"
            foreach ($p in $partitions) {
                Log "  Partition $($p.PartitionNumber)  Type=$($p.Type)  Letter=$($p.DriveLetter)  Size=$([math]::Round($p.Size/1MB))MB"
            }

            $winpePart = $partitions | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $winpePart) {
                throw "Could not find the Basic partition on Disk $diskNum after creation."
            }

            # Format using Format-Volume (reliable on fresh drives; diskpart format fails
            # with 'no volume selected' when the partition has never been formatted before)
            Log "Formatting Partition $($winpePart.PartitionNumber) as FAT32 (label: $volLabel)..."
            Get-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber |
                Format-Volume -FileSystem FAT32 -NewFileSystemLabel $volLabel -Force -Confirm:$false
            Log "Partition $($winpePart.PartitionNumber) formatted as FAT32."

            SetProgress "Assigning drive letters..." 30
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum

            try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -AccessPath "$($winpePart.DriveLetter):" } catch { Log "Warning: could not remove existing partition access path: $_" }
            $usbLetter = Get-FreeDriveLetter
            if (-not $usbLetter) { throw "No free drive letters (D-Z) available to assign to the USB data partition." }
            Set-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -NewDriveLetter $usbLetter
            Log "Assigned drive letter $usbLetter to WINPE partition (Partition $($winpePart.PartitionNumber))."
            Start-Sleep -Seconds 2

            $usbDrive = "${usbLetter}:"
            $retries = 0
            while (-not (Test-Path $usbDrive) -and $retries -lt 6) {
                $retries++
                Log "Waiting for $usbDrive to become accessible (attempt $retries/6)..."
                Start-Sleep -Seconds 2
            }
            if (-not (Test-Path $usbDrive)) { throw "Drive $usbDrive is not accessible after letter assignment." }
            Log "USB data partition: $usbDrive"

            $contentSizeBytes = (Get-ChildItem -LiteralPath $contentsDir -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if (-not $contentSizeBytes) { $contentSizeBytes = 0 }
            $usbVolume = Get-Volume -DriveLetter $usbLetter
            $partitionCapacityBytes = [int64]$usbVolume.Size
            $partitionFreeBytes = [int64]$usbVolume.SizeRemaining

            $contentSizeGB = [math]::Round($contentSizeBytes / 1GB, 2)
            $partitionCapacityGB = [math]::Round($partitionCapacityBytes / 1GB, 2)
            $partitionFreeGB = [math]::Round($partitionFreeBytes / 1GB, 2)

            Log "Source content size: $contentSizeGB GB. USB partition capacity: $partitionCapacityGB GB, free: $partitionFreeGB GB."

            if ($contentSizeBytes -gt $partitionCapacityBytes) {
                throw "ISO content ($contentSizeGB GB) is larger than the USB partition capacity ($partitionCapacityGB GB). Use a larger USB drive or reduce image size."
            }

            if ($contentSizeBytes -gt $partitionFreeBytes) {
                throw "Insufficient free space on USB partition. Required: $contentSizeGB GB, available: $partitionFreeGB GB."
            }

            SetProgress "Copying Windows 11 files to USB..." 45

            # Copy files; split install.wim if > 4 GB (FAT32 limit)
            $installWim = Join-Path $contentsDir "sources\install.wim"
            if (Test-Path $installWim) {
                $wimSizeMB = [math]::Round((Get-Item $installWim).Length / 1MB)
                if ($wimSizeMB -gt 3800) {
                    Log "install.wim is $wimSizeMB MB - splitting for FAT32 compatibility... This will take several minutes."
                    Set-ItemProperty -LiteralPath $installWim -Name IsReadOnly -Value $false
                    $splitDest = Join-Path $usbDrive "sources\install.swm"
                    New-Item -ItemType Directory -Path (Split-Path $splitDest) -Force
                    Split-WindowsImage -ImagePath $installWim -SplitImagePath $splitDest -FileSize 3800 -CheckIntegrity
                    Log "install.wim split complete."
                    Log "Copying remaining files to USB..."
                    & robocopy $contentsDir $usbDrive /E /XF install.wim /NFL /NDL /NJH /NJS
                } else {
                    & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
                }
            } else {
                & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
            }

            SetProgress "Finalising USB drive..." 90
            Log "Files copied to USB."
            SetProgress "USB write complete" 100
            Log "USB drive is ready for use."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "USB drive created successfully!`n`nYou can now boot from this drive to install Windows 11.",
                    "USB Ready", "OK", "Info")
            })
        } catch {
            Log "ERROR during USB write: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("USB write failed:`n`n$_", "USB Write Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Write-WinUtilLog -Component "Script" -Message "Running script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
        Write-WinUtilLog -Component "Script" -Message "Completed script for $Name"
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Command not found while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Runtime exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Security exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Access denied while running script for $Name`: $($PSItem.Exception.Message)"
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Unhandled exception while running script for $Name`: $($psitem.Exception.Message)"
    }

}

Function Invoke-WinUtilSponsors {
    $sponsors = ([regex]::Matches(([regex]::Match((Invoke-RestMethod https://github.com/sponsors/ChrisTitusTech),'(?s)(?<=Current sponsors).*?(?=Past sponsors)')).Value,'(?<=alt="@)[^"]+')).Value | Where-Object {$_ -ne "ChrisTitusTech"}
    return $sponsors
}

function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server... This will take a long time."
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "Starting the services"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$Home\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    }

    Write-Host "Configuring sshd_config for standard authorized_keys behavior..."
    $sshdConfigPath = "C:\ProgramData\ssh\sshd_config"

    $configContent = Get-Content -Path $sshdConfigPath -Raw

    $updatedContent = $configContent -replace '(?m)^(Match Group administrators)$', '# $1'
    $updatedContent = $updatedContent -replace '(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '# $1'

    if ($updatedContent -ne $configContent) {
        Set-Content -Path $sshdConfigPath -Value $updatedContent -Force
        Write-Host "Commented out administrator-specific SSH key configuration in sshd_config"
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config"
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}

function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($themeProperty in $themeProperties) {
            # Apply properties that deal with colors
            if ($themeProperty.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($themeProperty.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($themeProperty.Name)" -Value $themeProperty.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($themeProperty.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($themeProperty.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($themeProperty.Name -like "*Thickness*") -or ($themeProperty.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($themeProperty.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Reapply font scaling if it was previously set (theme change resets shared resources)
    if ($sync.ContainsKey("FontScaleFactor") -and $sync.FontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScaleFactor
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}

function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    $action = if ($undo) { "Undo" } else { "Apply" }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak: $CheckBox"

    if ($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if ($sync.configs.tweaks.$CheckBox.service) {
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if ($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if ($changeservice) {
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if ($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if ($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if (!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Remove-WinUtilAPPX -Name $psitem
            }
            Remove-WinUtilProvisionedAPPX -PackageList $sync.configs.tweaks.$CheckBox.appx
        }
    }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak completed: $CheckBox"
}

function Invoke-WinUtilUninstallPSProfile {

    if (Test-Path ($Profile + ".bak")) {
        Move-Item -Path ($Profile + ".bak") -Destination $Profile
    } else {
        Remove-Item -Path $Profile
    }

    Write-Host "Successfully uninstalled CTT PowerShell Profile." -ForegroundColor Green
}

function Invoke-WinUtilWithTimeout {
    <#
    .SYNOPSIS
        Runs a scriptblock with a hard time limit, returning -DefaultValue instead of
        blocking indefinitely if it doesn't finish in time.

    .DESCRIPTION
        For wrapping external commands that can occasionally hang or run far longer than
        normal - e.g. wsl.exe attempting to reach the Microsoft Store on a system where WSL
        isn't installed yet (a well-documented real-world quirk, not hypothetical), or
        Get-WindowsOptionalFeature against a slow or corrupted DISM/CBS state. Several
        prerequisite checks that need this run synchronously on the UI thread (Resolve-
        WinUtilPrerequisites has to, to show its modal dialog), so a hang there froze the
        whole app rather than just delaying a background operation.

        Runs the scriptblock in its own throwaway runspace (not $sync.runspace's pool - this
        is for occasional single-shot calls, not frequent background work) so a timeout here
        doesn't block the caller. On timeout, the still-running PowerShell instance is cleaned
        up asynchronously in the background rather than torn down synchronously - forcibly
        stopping some cmdlets (DISM in particular) can itself hang.

    .PARAMETER ScriptBlock
        Runs in a separate runspace - it has no access to variables/functions from the caller
        (including $sync), only built-in cmdlets/external commands and whatever -ArgumentList
        supplies.

    .PARAMETER OnWaiting
        Optional. For long timeouts (e.g. a multi-minute distro download) where silently
        blocking the whole wait looks indistinguishable from a genuine hang - confirmed live: a
        WSL distro install that was actually working (and did finish successfully) produced no
        console/progress feedback for its full 5-minute timeout window, and was reported as
        looking stalled. Unlike -ScriptBlock, this runs in the CALLING runspace/scope (it isn't
        passed into the isolated PowerShell instance), so it has normal access to things like
        Write-WinUtilLog or Set-WinUtilTweaksProgressIndicator. Called every -OnWaitingIntervalSeconds
        while still waiting, with the elapsed seconds so far as its argument. A caller that
        doesn't supply this gets the exact same single-wait behavior as before - the wait is
        internally chunked either way, but chunking with nothing to call between chunks is
        behaviorally identical to one long wait.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 8,

        $DefaultValue = $null,

        [scriptblock]$OnWaiting,

        [int]$OnWaitingIntervalSeconds = 15
    )

    if (-not ("WinUtilTimeoutCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class WinUtilTimeoutCleanupState
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilTimeoutCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilTimeoutCleanupState;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
        }
    }
}
"@ -ErrorAction Stop
    }

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($ScriptBlock)
    foreach ($arg in $ArgumentList) {
        [void]$ps.AddArgument($arg)
    }
    $handle = $ps.BeginInvoke()

    $elapsedSeconds = 0
    $completed = $false
    while ($elapsedSeconds -lt $TimeoutSeconds) {
        $waitChunk = [Math]::Min($OnWaitingIntervalSeconds, $TimeoutSeconds - $elapsedSeconds)
        if ($handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($waitChunk))) {
            $completed = $true
            break
        }
        $elapsedSeconds += $waitChunk
        if ($OnWaiting) {
            try { & $OnWaiting $elapsedSeconds } catch {}
        }
    }

    if ($completed) {
        try {
            $result = $ps.EndInvoke($handle)
            return $result
        } catch {
            return $DefaultValue
        } finally {
            $ps.Dispose()
        }
    }

    # Timed out - don't wait on or dispose it here (could itself hang); let it finish (or
    # not) in the background and get cleaned up once it does, via the thread pool.
    $cleanupState = [WinUtilTimeoutCleanupState]::new()
    $cleanupState.PowerShell = $ps
    $cleanupState.Handle = $handle
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject($handle.AsyncWaitHandle, [WinUtilTimeoutCleanup]::Callback, $cleanupState, -1, $true) | Out-Null
    return $DefaultValue
}

function New-WinUtilFossBadge {
    <#
        .SYNOPSIS
            Creates the FOSS marker: the open source keyhole on a green backdrop
        .DESCRIPTION
            Returns a fresh element on every call, because a WPF element can only have one parent.
            The artwork is authored in a 22x22 box and scaled by the Viewbox, so callers only pick a size.
        .PARAMETER Size
            Edge length of the badge in pixels
        .PARAMETER Round
            Use a full circle instead of the corner triangle, for the legend rather than an app entry
    #>
    param(
        [double]$Size = 24,
        [switch]$Round
    )

    $artwork = New-Object Windows.Controls.Grid
    $artwork.Width = 22
    $artwork.Height = 22

    $backdrop = New-Object Windows.Shapes.Path
    $backdrop.Fill = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))
    $keyhole = New-Object Windows.Shapes.Path
    $keyhole.Stroke = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(247, 247, 247))

    if ($Round) {
        $backdrop.Data = [Windows.Media.EllipseGeometry]::new([Windows.Point]::new(11, 11), 11, 11)
        # Keyhole centred in the circle, which has room for a larger ring than the triangle does
        $keyhole.Data = [Windows.Media.Geometry]::Parse("M 7.673,15.751 A 5.8,5.8 0 1 1 14.327,15.751")
        $keyhole.StrokeThickness = 3.4
    } else {
        # Triangle filling the top right corner, its outer corner rounded to match AppEntryBorderStyle
        $backdrop.Data = [Windows.Media.Geometry]::Parse("M 0,0 L 17,0 A 5,5 0 0 1 22,5 L 22,22 Z")
        # Keyhole centred on the triangle's incentre (15.56, 6.44) so it keeps the same
        # 1.8 clearance from all three edges
        $keyhole.Data = [Windows.Media.Geometry]::Parse("M 13.61,9.225 A 3.4,3.4 0 1 1 17.51,9.225")
        $keyhole.StrokeThickness = 2.4
    }

    $keyhole.StrokeStartLineCap = [Windows.Media.PenLineCap]::Round
    $keyhole.StrokeEndLineCap = [Windows.Media.PenLineCap]::Round
    [void]$artwork.Children.Add($backdrop)
    [void]$artwork.Children.Add($keyhole)

    $badge = New-Object Windows.Controls.Viewbox
    $badge.Width = $Size
    $badge.Height = $Size
    $badge.Child = $artwork
    $badge.ToolTip = "Free and Open Source Software"

    return $badge
}

function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX package pattern: $Name"

    # We explicitly loop through packages instead of using the pipeline because PowerShell 7 pipeline binding
    # for Remove-AppxPackage fails silently, and Get-AppxPackage -AllUsers returns duplicate objects for each user profile.
    $pkgs = Get-AppxPackage "*$Name*" -AllUsers | Sort-Object -Property PackageFullName -Unique
    if ($null -ne $pkgs) {
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX removal completed for package pattern: $Name"
}

function Remove-WinUtilProvisionedAPPX {
    <#

    .SYNOPSIS
        Removes all AppX provisioned packages that match the given names

    .PARAMETER PackageList
        An array of names of the APPX packages to remove

    .EXAMPLE
        Remove-WinUtilProvisionedAPPX -PackageList @("Microsoft.Microsoft3DViewer", "Microsoft.WindowsCalculator")

    #>
    param (
        [string[]]$PackageList
    )

    if ($null -eq $PackageList -or $PackageList.Count -eq 0) {
        return
    }

    Write-Host "`nRemoving provisioned packages..."
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX provisioned packages: $($PackageList -join ', ')"

    # DISM cmdlets like Get-AppxProvisionedPackage often fail with "Class not registered" or hang in PowerShell 7.
    # We shell out to Windows PowerShell 5.1 (powershell.exe) to reliably remove the provisioned packages.
    $ps5Command = {
        $pkgs = $args
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($Package in $pkgs) {
            $provs = $provisionedPackages |
                Where-Object DisplayName -Like "*$Package*"

            if ($null -ne $provs) {
                foreach ($prov in $provs) {
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                    }
                    catch {
                        $failures.Add("Failed to remove provisioned AppX package $($prov.PackageName): $($_.Exception.Message)")
                    }
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    $removalOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $PackageList 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -ne $removalOutput) {
        $failureDetails = ($removalOutput | Out-String).Trim()
        $errorMessage = "AppX provisioned package removal failed: $failureDetails"
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX provisioned package removal completed."
}

function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )
    $selectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures + $sync.selectedAppx), [StringComparer]::OrdinalIgnoreCase)

    # Setting .IsChecked below fires each checkbox's Checked/Unchecked handler, which calls
    # Invoke-WPFSelectedCheckboxesUpdate - that rebuilds the entire Selected Apps popup menu
    # from scratch on every single call. Toggling many checkboxes here (e.g. after a "Show
    # Installed Apps" scan finds a couple dozen already-installed apps) would otherwise trigger
    # that full rebuild once per checkbox - O(n^2) menu rebuilds - even though this function
    # already does the definitive rebuild itself, once, right below. Suppress the per-checkbox
    # rebuild for the duration of this loop.
    $sync.SuppressSelectedAppsMenuRebuild = $true
    try {
        foreach ($syncEntry in $sync.GetEnumerator()) {
            if ($syncEntry.Value -is [System.Windows.Controls.CheckBox] -and $syncEntry.Name -notlike "WPFToggle*" -and $syncEntry.Name -like $checkboxfilterpattern) {
                $checkboxName = $syncEntry.Key
                $sync.$checkboxName.IsChecked = $selectedSet.Contains($checkboxName)
            }
        }
    } finally {
        $sync.SuppressSelectedAppsMenuRebuild = $false
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "Selected Apps: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedToggles), [StringComparer]::OrdinalIgnoreCase)
        foreach ($toggle in $sync.GetEnumerator()) {
            if ($toggle.Key -like "WPFToggle*" -and $toggle.Value -is [System.Windows.Controls.CheckBox] -and $importedToggles.Contains($toggle.Key)) {
                $sync[$toggle.Key].IsChecked = $true
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}

function Resolve-WinUtilPackagePrompts {
    <#
    .SYNOPSIS
        For each package that declares "prompts" (e.g. a password to bake into a command),
        shows an input dialog and attaches the entered values as .PromptValues. If the user
        cancels, the package is dropped from the run.

        Must be called from the UI thread - before the selection is handed off to the
        background install runspace, which may not be an STA thread and cannot reliably
        show its own dialogs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$PackagesToInstall
    )

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $PackagesToInstall) {
        if (-not $package.prompts -or @($package.prompts).Count -eq 0) {
            $result.Add($package)
            continue
        }

        $values = Show-WinUtilPromptDialog -Title $package.content -Message "$($package.content) needs a few values before installing:" -Prompts $package.prompts

        if ($null -eq $values) {
            Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping $($package.content) - prompt cancelled."
            continue
        }

        $packageWithValues = $package | Add-Member -NotePropertyName PromptValues -NotePropertyValue $values -PassThru -Force
        $result.Add($packageWithValues)
    }

    # The leading comma matters: PowerShell unwraps a returned empty array to $null across the
    # function-return boundary (e.g. if every remaining package's prompt gets cancelled) - see
    # Resolve-WinUtilPrerequisites.ps1 for the exception that caused downstream.
    return ,$result.ToArray()
}

function Resolve-WinUtilPrerequisites {
    <#
    .SYNOPSIS
        For each package that declares "requires", checks whether each required catalog
        entry is already installed; if not, offers (Yes/No) to install it alongside the
        selection. If declined, the dependent package is dropped from the run.

        Must be called from the UI thread (shows a modal Yes/No dialog) - before the
        selection is handed off to the background install runspace.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$PackagesToInstall
    )

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $PackagesToInstall) { $result.Add($p) }

    $queuedKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $result) {
        if ($p.Key) { [void]$queuedKeys.Add([string]$p.Key) }
    }

    # WSL2 needs hardware virtualization (Intel VT-x / AMD-V) enabled in firmware - unlike the
    # Windows optional features it also needs, there's no "install this for you" fix since it's
    # a BIOS/UEFI setting, so this runs before the normal requires-resolution below and drops
    # WSL2 (and anything already queued that needs it: Debian, Docker Desktop, Olivetin) outright
    # rather than offering the usual Yes/No prompt. Only a definite $false blocks anything - a
    # $null result (can't be determined) is not evidence virtualization is actually unavailable.
    $needsWsl2 = @($result) | Where-Object {
        $_.installType -eq "wslFeature" -or ($_.requires -and $_.requires -contains "wsl2")
    }
    if ($needsWsl2.Count -gt 0 -and (Test-WinUtilVirtualizationFirmwareEnabled) -eq $false) {
        $names = ($needsWsl2 | ForEach-Object { $_.content }) -join ", "
        [void](Show-WinUtilMessage -Message "WSL2 requires hardware virtualization (Intel VT-x / AMD-V), which appears to be disabled in this PC's BIOS/UEFI firmware settings. Enable it there, then try again.`n`nSkipping: $names" -Title "Virtualization is disabled" -Button ([System.Windows.MessageBoxButton]::OK) -Icon "Warning")
        Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping WSL2-dependent packages - hardware virtualization firmware appears disabled: $names"
        foreach ($p in $needsWsl2) {
            [void]$result.Remove($p)
            if ($p.Key) { [void]$queuedKeys.Remove([string]$p.Key) }
        }
    }

    $toDrop = [System.Collections.Generic.List[object]]::new()

    foreach ($package in @($result)) {
        if (-not $package.requires -or @($package.requires).Count -eq 0) { continue }

        $missing = [System.Collections.Generic.List[object]]::new()
        foreach ($reqKey in $package.requires) {
            if ($queuedKeys.Contains([string]$reqKey)) { continue }

            $reqEntry = $sync.configs.applicationsHashtable."WPFInstall$reqKey"
            if (-not $reqEntry) {
                Write-WinUtilLog -Level "WARN" -Component "Install" -Message "$($package.content) declares unknown prerequisite '$reqKey'."
                continue
            }

            $isInstalled = switch ($reqEntry.installType) {
                "wslFeature" { Test-WinUtilWSLFeatureEnabled }
                "wslDistro" { Test-WinUtilWSLDistroInstalled -Distro $reqEntry.distro }
                default { Test-WinUtilProgramInstalled -WingetId $reqEntry.winget -ChocoId $reqEntry.choco }
            }

            if (-not $isInstalled) {
                $missing.Add([pscustomobject]@{ Key = $reqKey; Entry = $reqEntry })
            }
        }

        if ($missing.Count -eq 0) { continue }

        $names = ($missing | ForEach-Object { $_.Entry.content }) -join ", "
        $response = Show-WinUtilMessage -Message "$($package.content) requires: $names`n`nInstall these now too?" -Title "Missing prerequisites" -Button ([System.Windows.MessageBoxButton]::YesNo) -Icon "Question"

        if ($response -eq [System.Windows.MessageBoxResult]::Yes) {
            foreach ($m in $missing) {
                if ($queuedKeys.Contains([string]$m.Key)) { continue }
                $entryWithKey = $m.Entry | Add-Member -NotePropertyName Key -NotePropertyValue $m.Key -PassThru -Force
                $result.Add($entryWithKey)
                [void]$queuedKeys.Add([string]$m.Key)
            }
        } else {
            Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping $($package.content) - required prerequisites declined: $names"
            $toDrop.Add($package)
        }
    }

    foreach ($d in $toDrop) { [void]$result.Remove($d) }

    # WSL2, unlike the other prerequisites here, typically needs a system restart the first time
    # it's enabled before it's actually usable - installing a distro (or anything that needs a
    # working WSL2, e.g. Docker Desktop) in the very same run as enabling WSL2 for the first time
    # is likely to fail even though the WSL2 feature install itself succeeded (this is what
    # happened: WSL2 enabled fine, the immediately-following Debian install then failed). Only
    # gates when WSL2 wasn't already enabled before this run - if it's already usable, there's
    # nothing to restart for, and everything proceeds normally in one run as before.
    if (-not (Test-WinUtilWSLFeatureEnabled)) {
        $wslDependents = @($result) | Where-Object {
            $_.installType -ne "wslFeature" -and ($_.installType -eq "wslDistro" -or ($_.requires -and $_.requires -contains "wsl2"))
        }
        if ($wslDependents.Count -gt 0) {
            $names = ($wslDependents | ForEach-Object { $_.content }) -join ", "
            [void](Show-WinUtilMessage -Message "WSL2 needs a system restart before it can actually be used - installing it and then immediately installing $names in the same run is likely to fail. This run will enable WSL2 only.`n`nRestart your PC, then come back and install: $names" -Title "Restart required for WSL2" -Button ([System.Windows.MessageBoxButton]::OK) -Icon "Warning")
            Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping WSL2-dependent packages this run - WSL2 was not already enabled and typically needs a restart first: $names"
            foreach ($p in $wslDependents) {
                [void]$result.Remove($p)
                if ($p.Key) { [void]$queuedKeys.Remove([string]$p.Key) }
            }
        }
    }

    # Packages sharing the same install bucket (e.g. Docker Desktop and Debian both installing
    # via winget) had no ordering relative to each other before this - see
    # Get-WinUtilPackagesInDependencyOrder.ps1 for the confirmed real case that prompted it.
    $orderedResult = Get-WinUtilPackagesInDependencyOrder -Packages @($result)

    # The leading comma matters: PowerShell unwraps a returned empty array to $null across the
    # function-return boundary, and $null then fails to bind to Resolve-WinUtilPackagePrompts's
    # mandatory [object[]] parameter (e.g. every selected package had a declined/blocked
    # prerequisite) - a ParameterArgumentValidationErrorNullNotAllowed exception instead of the
    # intended "nothing left to install" no-op.
    return ,$orderedResult
}

function Save-WinUtilFile {
    <#
    .SYNOPSIS
        Downloads a file and reports transfer progress.
    #>
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [scriptblock]$ProgressCallback
    )

    $response = $null
    $responseStream = $null
    $outputStream = $null

    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $responseStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($DestinationPath)
        $buffer = New-Object byte[] 81920
        $downloadedBytes = 0L
        $lastPercent = -1

        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloadedBytes / $totalBytes) * 100))
                if ($percent -ne $lastPercent) {
                    & $ProgressCallback $percent
                    $lastPercent = $percent
                }
            }
        }

        if ($lastPercent -ne 100) {
            & $ProgressCallback 100
        }
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $responseStream) {
            $responseStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Set-WinUtilAppCategoryFilter {
    <#
        .SYNOPSIS
            Applies an exact application category filter from an Install tab search chip.

        .PARAMETER Category
            The application category to show. An empty value clears the filter.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Category = ""
    )

    $sync.SearchBar.Tag = $Category
    $sync.SearchBar.Text = $Category
    Find-AppsByNameOrDescription -SearchString $Category -Category $Category
}

function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)

    if($DNSProvider -eq "Default") {
        Write-WinUtilLog -Component "DNS" -Message "DNS provider is Default; no DNS changes applied."
        return
    }

    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)
        Write-WinUtilLog -Component "DNS" -Message "Setting DNS provider to $DNSProvider for $(@($Adapters).Count) active adapter(s)."

        if($DNSProvider -ne "DHCP") {
            $dns = $sync.configs.dns.$DNSProvider
            if($null -eq $dns) {
                Write-Warning "DNS provider $DNSProvider was not found in configuration."
                Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not found in configuration."
                return
            }
        }

        $dohSupported = [bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
        $dnscacheBase = "HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters"

        Foreach ($Adapter in $Adapters) {
            $interfaceParams = "$dnscacheBase\$($Adapter.InterfaceGuid)"

            if($DNSProvider -eq "DHCP") {
                Write-WinUtilLog -Component "DNS" -Message "Resetting DNS to DHCP on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex))."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
                netsh interface ip set dnsservers name="$($Adapter.Name)" source=dhcp
                netsh interface ipv6 set dnsservers name="$($Adapter.Name)" source=dhcp

                $dohInterfaceSettings = "$interfaceParams\DohInterfaceSettings"
                if (Test-Path $dohInterfaceSettings) {
                    if ($dohSupported) {
                        $dohServerAddresses = @(
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh" -ErrorAction SilentlyContinue
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh6" -ErrorAction SilentlyContinue
                        ) | Select-Object -ExpandProperty PSChildName -Unique

                        foreach ($ip in $dohServerAddresses) {
                            if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
                                Write-WinUtilLog -Component "DNS" -Message "Removing DoH registration for $ip."
                                Remove-DnsClientDohServerAddress -ServerAddress $ip -Confirm:$false -ErrorAction Stop
                            }
                        }
                    }

                    Remove-Item -Path $dohInterfaceSettings -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv4 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary), $($dns.Secondary)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary, $dns.Secondary)
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv6 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary6), $($dns.Secondary6)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary6, $dns.Secondary6)

                if ($dohSupported -and $dns.DohTemplate) {
                    $ips = @($dns.Primary, $dns.Secondary, $dns.Primary6, $dns.Secondary6) | Where-Object { $_ }
                    foreach ($ip in $ips) {
                        $existing = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
                        if ($existing) {
                            Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dns.DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                        } else {
                            Write-WinUtilLog -Component "DNS" -Message "Registering DoH template for $ip."
                            Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dns.DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                        }
                        
                        $leaf = if ($ip.Contains(':')) { 'Doh6' } else { 'Doh' }
                        $regPath = "$interfaceParams\DohInterfaceSettings\$leaf\$ip"
                        
                        if (-not (Test-Path $regPath)) {
                            New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
                        }
                        New-ItemProperty -Path $regPath -Name "DohFlags" -Value 1 -PropertyType QWord -Force -ErrorAction Stop | Out-Null
                    }
                }
            }
        }
        if ($DNSProvider -ne "DHCP" -and $dohSupported -and $dns.DohTemplate) {
            Clear-DnsClientCache
        }
        Write-WinUtilLog -Component "DNS" -Message "DNS provider change completed: $DNSProvider"
    } catch {
        Write-Warning "DNS provider $DNSProvider was not completed because an error occurred."
        Write-Warning $psitem.Exception.Message
        Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not completed: $($psitem.Exception.Message)"
    }
}

function Set-WinUtilNoBomFileContent {
    <#
    .SYNOPSIS
        Writes text to a file as UTF-8 without a byte-order-mark, regardless of PowerShell
        version/host.

    .DESCRIPTION
        Set-Content -Encoding UTF8 is not consistent across PowerShell versions - confirmed
        live: Windows PowerShell 5.1 prepends a BOM (bytes EF BB BF) for "UTF8", PowerShell 7+
        does not, for the exact same command. A BOM at the start of a file bash then reads as a
        script corrupts its first word, since bash doesn't strip it - this is exactly what
        Install-WinUtilWSLCommand.ps1 hit: a WSL install command starting with "docker" failed
        with "command not found", because the actual first bytes bash saw were the BOM followed
        by "docker", not "docker" itself.

        A thin wrapper around [System.IO.File]::WriteAllText with an explicit
        UTF8Encoding($false), rather than calling that directly at each use site - Pester can
        mock a PowerShell function, but not a static .NET method call, so call sites that need
        to be testable (without actually writing through a real \\wsl.localhost UNC path) go
        through this instead of the raw .NET API.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $noBomUtf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Value, $noBomUtf8)
}

function Set-WinUtilProcessForeground {
    <#
    .SYNOPSIS
        Brings a just-started process's main window to the foreground.

    .DESCRIPTION
        Interactive installers launched from WinUtil's background install runspace don't
        reliably get Windows' automatic foreground grant - that's tied to whichever thread
        most recently received user input (the UI thread that handled the button click), not
        the background thread that actually calls Start-Process. Polls briefly for the new
        process's main window to appear, then explicitly foregrounds it. Uses the well-known
        ALT-keypress workaround for SetForegroundWindow's foreground-lock restriction (a
        simulated key event satisfies the "was this the last input" check Windows applies).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [int]$TimeoutSeconds = 15
    )

    if (-not ([System.Management.Automation.PSTypeName]'WinUtil.ForegroundWindowNative').Type) {
        Add-Type -Namespace WinUtil -Name ForegroundWindowNative -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@ -ErrorAction Stop
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { return }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 200
    }

    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { return }

    if ([WinUtil.ForegroundWindowNative]::IsIconic($Process.MainWindowHandle)) {
        [void][WinUtil.ForegroundWindowNative]::ShowWindow($Process.MainWindowHandle, 9)  # SW_RESTORE
    }

    [WinUtil.ForegroundWindowNative]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # VK_MENU (Alt) down
    [void][WinUtil.ForegroundWindowNative]::SetForegroundWindow($Process.MainWindowHandle)
    [WinUtil.ForegroundWindowNative]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # Alt up (KEYEVENTF_KEYUP)
}

function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            Write-WinUtilLog -Component "Registry" -Message "Creating registry path: $Path"
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Write-WinUtilLog -Component "Registry" -Message "Setting $Path\$Name ($Type) to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Write-WinUtilLog -Component "Registry" -Message "Removing $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Security exception while changing $Path\$Name to $Value`: $($psitem.Exception.Message)"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Registry item not found while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
       Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unauthorized while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unhandled exception while changing $Path\$Name`: $($psitem.Exception.Message)"
    }
}

Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"
        Write-WinUtilLog -Component "Service" -Message "Setting service $Name startup type to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        if (($service.PSObject.Properties.Name -contains "StartType") -and ([string]$service.StartType -eq [string]$StartupType) ) {
            Write-Host "Service $Name is already set to $StartupType"
            Write-WinUtilLog -Component "Service" -Message "Service $Name startup type is already $StartupType; no change needed."
            return
        }

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
        Write-WinUtilLog -Component "Service" -Message "Service $Name startup type set to $StartupType"
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Warning "Service $Name was not found."
            Write-WinUtilLog -Level "WARN" -Component "Service" -Message "Service $Name was not found."
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception."
            Write-Warning $_.Exception.Message
            Write-WinUtilLog -Level "ERROR" -Component "Service" -Message "Unable to set service $Name to $StartupType`: $($_.Exception.Message)"
        }
    }

}

function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                if (-not $sync["logorender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                if (-not $sync["checkmarkrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                if (-not $sync["warningrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}

function Set-WinUtilTweaksProgressIndicator {
    <#
    .SYNOPSIS
        Shows, updates, or hides the window-level progress indicator used by long-running
        workflows such as app management, Tweaks, AppX management, and Win11 Creator.
        It lives outside the TabControl, so it stays visible no matter which tab is active.
    .PARAMETER Visible
        Whether the indicator should be shown or hidden.
    .PARAMETER Label
        The text to display above the progress bar.
    .PARAMETER Percent
        The percentage of the progress bar that should be filled (0-100).
    #>
    param(
        [bool]$Visible,
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    $indicatorVisible = if ($Visible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $indicatorLabel = $Label
    $hasLabel = $PSBoundParameters.ContainsKey('Label')
    $hasPercent = $PSBoundParameters.ContainsKey('Percent')

    Invoke-WPFUIThread -ScriptBlock {
        $sync.WPFTweaksProgressBar.Visibility = $indicatorVisible
        if ($hasLabel) {
            $sync.WPFTweaksProgressLabel.Text = $indicatorLabel
        }
        if ($hasPercent) {
            $sync.WPFTweaksProgressValue.Value = $Percent
        }
    }
}

function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "WinUtil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0
    $linkHoverBrush = $LinkHoverForegroundColor

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            Start-Process $eventSender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $linkHoverBrush
            $eventSender.FontSize = ($FontSize + ($FontSize / 4))
            $eventSender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $LinkForegroundColor
            $eventSender.FontSize = $FontSize
            $eventSender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}

function Show-WinUtilMessage {
    <#
    .SYNOPSIS
        Shows a WinUtil message box and returns the selected result.
    #>
    param (
        [string]$Message,
        [string]$Title = "Winutil",
        $Button = "OK",
        $Icon = "Information"
    )

    [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
}

function Show-WinUtilPromptDialog {
    <#
    .SYNOPSIS
        Shows a themed dialog with one text/password field per declared prompt and
        OK/Cancel buttons. Must be called from the UI thread (not a background runspace).

    .PARAMETER Title
        Dialog title text.

    .PARAMETER Message
        Explanatory message shown above the input fields.

    .PARAMETER Prompts
        Array of objects with at least a "name" and "label"; optional "secret" (bool) masks
        the field and adds a Show/Hide toggle; optional "minLength" (int) rejects OK until
        the entered value meets that length.

    .OUTPUTS
        Hashtable of name -> entered value, or $null if the dialog was cancelled.
    #>
    param(
        [string]$Title = "WinUtil",
        [string]$Message = "",
        [Parameter(Mandatory = $true)]
        [object[]]$Prompts
    )

    $ForegroundColor = $sync.Form.Resources.MainForegroundColor
    $BackgroundColor = $sync.Form.Resources.MainBackgroundColor
    $BorderColor = $sync.Form.Resources.BorderColor
    $ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor
    $ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor

    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.SizeToContent = [Windows.SizeToContent]::Height
    $dialog.Width = 420
    $dialog.WindowStyle = [Windows.WindowStyle]::None
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $sync.Form.Resources.FontFamily

    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)
    $border.CornerRadius = New-Object Windows.CornerRadius(10)
    $dialog.Content = $border

    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = New-Object Windows.Thickness(16)
    $border.Child = $stack

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $msgBlock = New-Object Windows.Controls.TextBlock
        $msgBlock.Text = $Message
        $msgBlock.TextWrapping = [Windows.TextWrapping]::Wrap
        $msgBlock.Margin = New-Object Windows.Thickness(0, 0, 0, 12)
        [void]$stack.Children.Add($msgBlock)
    }

    $errorBlock = New-Object Windows.Controls.TextBlock
    $errorBlock.Foreground = [Windows.Media.Brushes]::OrangeRed
    $errorBlock.TextWrapping = [Windows.TextWrapping]::Wrap
    $errorBlock.Margin = New-Object Windows.Thickness(0, 0, 0, 8)
    $errorBlock.Visibility = [Windows.Visibility]::Collapsed
    [void]$stack.Children.Add($errorBlock)

    # $inputs[name] holds a small record per field: what controls back it, whether it's a
    # secret field (Show/Hide toggle over a PasswordBox+TextBox pair), and its MinLength.
    $inputs = @{}
    foreach ($prompt in $Prompts) {
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $prompt.label
        $label.Margin = New-Object Windows.Thickness(0, 6, 0, 2)
        [void]$stack.Children.Add($label)

        $minLength = if ($prompt.minLength) { [int]$prompt.minLength } else { 0 }

        if ($prompt.secret) {
            $fieldGrid = New-Object Windows.Controls.Grid
            $col1 = New-Object Windows.Controls.ColumnDefinition
            $col1.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
            $col2 = New-Object Windows.Controls.ColumnDefinition
            $col2.Width = [Windows.GridLength]::Auto
            [void]$fieldGrid.ColumnDefinitions.Add($col1)
            [void]$fieldGrid.ColumnDefinitions.Add($col2)

            $passwordField = New-Object Windows.Controls.PasswordBox
            $textField = New-Object Windows.Controls.TextBox
            $textField.Visibility = [Windows.Visibility]::Collapsed
            [Windows.Controls.Grid]::SetColumn($passwordField, 0)
            [Windows.Controls.Grid]::SetColumn($textField, 0)
            [void]$fieldGrid.Children.Add($passwordField)
            [void]$fieldGrid.Children.Add($textField)

            $toggleButton = New-Object Windows.Controls.Button
            $toggleButton.Content = "Show"
            $toggleButton.Width = 50
            $toggleButton.Margin = New-Object Windows.Thickness(6, 0, 0, 0)
            [Windows.Controls.Grid]::SetColumn($toggleButton, 1)
            [void]$fieldGrid.Children.Add($toggleButton)

            $toggleButton.Add_Click({
                if ($textField.Visibility -eq [Windows.Visibility]::Visible) {
                    $passwordField.Password = $textField.Text
                    $textField.Visibility = [Windows.Visibility]::Collapsed
                    $passwordField.Visibility = [Windows.Visibility]::Visible
                    $toggleButton.Content = "Show"
                } else {
                    $textField.Text = $passwordField.Password
                    $passwordField.Visibility = [Windows.Visibility]::Collapsed
                    $textField.Visibility = [Windows.Visibility]::Visible
                    $toggleButton.Content = "Hide"
                }
            })

            $fieldGrid.Margin = New-Object Windows.Thickness(0, 0, 0, 4)
            [void]$stack.Children.Add($fieldGrid)
            $inputs[$prompt.name] = [pscustomobject]@{
                Secret        = $true
                PasswordField = $passwordField
                TextField     = $textField
                MinLength     = $minLength
                Label         = $prompt.label
            }
        } else {
            $field = New-Object Windows.Controls.TextBox
            $field.Margin = New-Object Windows.Thickness(0, 0, 0, 4)
            [void]$stack.Children.Add($field)
            $inputs[$prompt.name] = [pscustomobject]@{
                Secret    = $false
                TextField = $field
                MinLength = $minLength
                Label     = $prompt.label
            }
        }
    }

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $buttonPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    $buttonPanel.Margin = New-Object Windows.Thickness(0, 12, 0, 0)
    [void]$stack.Children.Add($buttonPanel)

    $script:winutilPromptResult = $null

    # No .GetNewClosure() on any of these handlers - ShowDialog() blocks below, keeping this
    # function's scope alive on the call stack for as long as the dialog is open, so plain
    # lexical scoping already reaches $inputs/$dialog/$errorBlock correctly. GetNewClosure()
    # was tested and found to NOT reliably resolve captured variables when a scriptblock is
    # invoked as a genuine WPF routed-event delegate (as opposed to a direct `&` call) - it
    # silently produced an empty $result instead of the entered values, with no error surfaced.
    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Content = "Cancel"
    $cancelButton.Width = 80
    $cancelButton.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
    $cancelButton.Add_Click({
        $script:winutilPromptResult = $null
        $dialog.Close()
    })
    [void]$buttonPanel.Children.Add($cancelButton)

    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.Width = 80
    $okButton.Background = $ButtonBackgroundColor
    $okButton.Foreground = $ButtonForegroundColor
    $okButton.IsDefault = $true
    $okButton.Add_Click({
        $result = @{}
        $validationErrors = @()

        foreach ($entry in $inputs.GetEnumerator()) {
            $info = $entry.Value
            $value = if ($info.Secret) {
                if ($info.TextField.Visibility -eq [Windows.Visibility]::Visible) { $info.TextField.Text } else { $info.PasswordField.Password }
            } else {
                $info.TextField.Text
            }

            if ($info.MinLength -gt 0 -and $value.Length -lt $info.MinLength) {
                $validationErrors += "$($info.Label) must be at least $($info.MinLength) characters."
            }

            $result[$entry.Key] = $value
        }

        if ($validationErrors.Count -gt 0) {
            $errorBlock.Text = $validationErrors -join "`n"
            $errorBlock.Visibility = [Windows.Visibility]::Visible
            return
        }

        $script:winutilPromptResult = $result
        $dialog.Close()
    })
    [void]$buttonPanel.Children.Add($okButton)

    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $script:winutilPromptResult = $null
            $dialog.Close()
        }
    })

    $dialog.ShowDialog() | Out-Null
    return $script:winutilPromptResult
}

function Invoke-WinUtilInstallAppRenderBatch {
    param(
        [Parameter(Mandatory = $true)]
        $CategoryBatch
    )

    foreach ($appKey in $CategoryBatch.AppKeys) {
        $sync.$appKey = Initialize-InstallAppEntry -TargetElement $CategoryBatch.TargetElement -AppKey $appKey
    }

    if ($sync.currentTab -eq "Install" -and $sync.SearchBar -and -not [string]::IsNullOrWhiteSpace($sync.SearchBar.Text)) {
        Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Category $sync.SearchBar.Tag
    }
}

function Complete-WinUtilInstallAppRendering {
    $sync.InstallAppEntriesRendered = $true
}

function Invoke-WinUtilInstallAppRenderNextBatch {
    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    Complete-WinUtilInstallAppRendering
}

function Start-WinUtilInstallAppRendering {
    if ($null -eq $sync.InstallAppRenderQueue) {
        return
    }

    $sync.InstallAppEntriesRendered = $false

    if ($sync.Form -and $sync.Form.Dispatcher) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    while ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    Complete-WinUtilInstallAppRendering
}

function Start-WinUtilProcessAsStandardUser {
    <#
    .SYNOPSIS
        Launches a process at the user's normal (non-elevated) integrity level from within
        WinUtil's elevated process - for operations like winget that behave incorrectly (or
        refuse outright) when run as Administrator against per-user-scope packages.

    .DESCRIPTION
        Uses a temporary Scheduled Task with RunLevel "Limited" (TASK_RUNLEVEL_LUA) to launch
        the target. That RunLevel is the OS-documented mechanism for forcing a task to run
        with the user's standard, filtered token even when the principal is an administrator
        and the caller registering the task is elevated - Task Scheduler itself performs the
        de-elevation, so there's no dependency on token APIs or COM behaving a particular way.

        Two earlier approaches were tried and both proved unreliable in practice:
        - CreateProcessWithTokenW with the UAC "linked" standard-user token looked correct on
          paper (SeImpersonatePrivilege enabled, valid linked token) but reliably failed with
          ERROR_ACCESS_DENIED (Win32 error 5) when called from an ordinary elevated process.
          That API is implemented via the Secondary Logon service, which applies extra checks
          effectively restricting it to LocalSystem-level callers, not elevated Administrator
          tokens.
        - Shell.Application COM's ShellExecute (the commonly-referenced "ask Explorer to
          launch it" trick) silently did not de-elevate: New-Object -ComObject
          "Shell.Application" from an elevated process instantiates the COM object in-process
          rather than marshaling out to the existing non-elevated explorer.exe, so the launched
          process just inherited our elevated token anyway.

        Because Start-ScheduledTask is fire-and-forget (no process handle/PID is returned),
        the actual target is launched indirectly via a small generated wrapper .ps1 that runs
        it with Start-Process -Wait, then writes the resulting exit code to a sentinel file.
        This helper polls for that file so callers still get a reliable exit code, the same
        way they would from Start-Process -PassThru -Wait.

        Falls back to running the process normally (at the current, elevated, integrity) if
        any step fails or times out - this is a best-effort correctness improvement, not
        something that should ever hard-fail an install/uninstall.

    .OUTPUTS
        A [pscustomobject] with an .ExitCode property, so callers can read it the same way
        they would with Start-Process -PassThru -Wait.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 300
    )

    $wrapperScript = $null
    $sentinelFile = $null
    $taskName = $null

    try {
        $workingDir = Split-Path -Path $FilePath -Parent
        if ([string]::IsNullOrWhiteSpace($workingDir)) { $workingDir = $env:TEMP }

        $token = [guid]::NewGuid().ToString("N")
        $wrapperScript = Join-Path $env:TEMP "cdvr-deelevate-$token.ps1"
        $sentinelFile = Join-Path $env:TEMP "cdvr-deelevate-$token.txt"
        $taskName = "CDVR-WinUtil-Deelevate-$token"

        $argArrayLiteral = "@(" + (($ArgumentList | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ")"
        $filePathLiteral = "'" + ($FilePath -replace "'", "''") + "'"
        $sentinelLiteral = "'" + ($sentinelFile -replace "'", "''") + "'"

        $wrapperContent = @"
try {
    `$p = Start-Process -FilePath $filePathLiteral -ArgumentList $argArrayLiteral -NoNewWindow -Wait -PassThru
    `$p.ExitCode | Out-File -FilePath $sentinelLiteral -Encoding ascii
} catch {
    "ERROR: `$_" | Out-File -FilePath $sentinelLiteral -Encoding ascii
}
"@
        Set-Content -Path $wrapperScript -Value $wrapperContent -Encoding UTF8

        Import-Module ScheduledTasks -ErrorAction Stop

        $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $shellArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapperScript`""
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $shellArgs -WorkingDirectory $workingDir
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel
        $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings

        Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-Path $sentinelFile) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
        }

        if (-not (Test-Path $sentinelFile)) {
            throw "Timed out after ${TimeoutSeconds}s waiting for de-elevated process to complete."
        }

        $result = (Get-Content -Path $sentinelFile -Raw).Trim()
        if ($result -like "ERROR:*") {
            throw "De-elevated process wrapper failed: $result"
        }

        $exitCode = [int]$result
        return [pscustomobject]@{ ExitCode = $exitCode }
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Could not run $FilePath as standard user, running elevated instead: $_"
        return Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru
    } finally {
        if ($taskName -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        foreach ($f in @($wrapperScript, $sentinelFile)) {
            if ($f -and (Test-Path $f)) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Test-WinUtilDockerAvailableInWSL {
    <#
    .SYNOPSIS
        Checks whether the "docker" CLI is actually reachable and working inside a given WSL
        distro - not just that Docker Desktop itself is installed.

    .DESCRIPTION
        Resolve-WinUtilPrerequisites already confirms Docker Desktop is installed before letting
        anything that "requires" it proceed, but installing the app doesn't automatically enable
        WSL integration for any particular distro - that's a separate, manual toggle in Docker
        Desktop's own Settings > Resources > WSL Integration, easy to miss. Without it, the
        "docker" command simply doesn't exist inside that distro at all - confirmed live: an
        Olivetin install failed with "docker: command not found" deep inside its own install
        script, with nothing pointing at the actual cause or fix.

        Distinguishes two different failure modes with two different fixes, rather than one
        generic "docker isn't available" message:
          - The "docker" command itself isn't on PATH in the distro - WSL integration isn't
            enabled for it.
          - "docker" exists but can't reach the daemon - Docker Desktop isn't running, or is
            still starting up.

        Bounded via Invoke-WinUtilWithTimeout, matching every other wsl.exe call in this app -
        the same class of hang risk applies here as anywhere else that shells out to wsl.exe.

    .OUTPUTS
        A [pscustomobject] with .Available ($true/$false) and .Reason - a specific, actionable
        message when .Available is $false, or $null when it's $true.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    $cliPresent = Invoke-WinUtilWithTimeout -TimeoutSeconds 15 -DefaultValue $false -ArgumentList @($Distro) -ScriptBlock {
        param($Distro)
        try {
            & wsl -d $Distro -- bash -c "command -v docker" 2>&1 | Out-Null
            return $LASTEXITCODE -eq 0
        } catch {
            return $false
        }
    }

    if (-not $cliPresent) {
        return [pscustomobject]@{
            Available = $false
            Reason = "The 'docker' command isn't available inside the $Distro WSL distro. In Docker Desktop, go to Settings > Resources > WSL Integration and enable integration for '$Distro', then try again."
        }
    }

    $daemonReachable = Invoke-WinUtilWithTimeout -TimeoutSeconds 15 -DefaultValue $false -ArgumentList @($Distro) -ScriptBlock {
        param($Distro)
        try {
            & wsl -d $Distro -- docker info 2>&1 | Out-Null
            return $LASTEXITCODE -eq 0
        } catch {
            return $false
        }
    }

    if (-not $daemonReachable) {
        return [pscustomobject]@{
            Available = $false
            Reason = "The 'docker' command is available inside $Distro, but can't reach the Docker daemon. Make sure Docker Desktop is running and has finished starting, then try again."
        }
    }

    return [pscustomobject]@{ Available = $true; Reason = $null }
}

function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        WinGet is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}

function Test-WinUtilProgramInstalled {
    <#
    .SYNOPSIS
        Returns $true if a winget or choco package ID is already installed. Used for
        prerequisite checks (e.g. is Docker Desktop / Node.js already present).
    #>
    param(
        [string]$WingetId,
        [string]$ChocoId
    )

    if (-not [string]::IsNullOrWhiteSpace($WingetId) -and $WingetId -ne "na") {
        try {
            # --exact matters here: without it, winget does fuzzy prefix matching and can
            # silently resolve to a different, unrelated package (e.g. "Google.Chrome" fuzzy-
            # matched "Google.Chrome.Beta.EXE" and reported its version info instead).
            $result = & winget list --id $WingetId --exact --accept-source-agreements --disable-interactivity 2>&1
            if ($LASTEXITCODE -eq 0 -and (($result -join "`n") -match [regex]::Escape($WingetId))) {
                return $true
            }
        } catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($ChocoId) -and $ChocoId -ne "na") {
        try {
            $result = & choco list --local-only $ChocoId 2>&1
            if ($LASTEXITCODE -eq 0 -and (($result -join "`n") -match [regex]::Escape($ChocoId))) {
                return $true
            }
        } catch {}
    }

    return $false
}

function Test-WinUtilVirtualizationFirmwareEnabled {
    <#
    .SYNOPSIS
        Returns $true/$false when hardware virtualization (Intel VT-x / AMD-V) is known to be
        enabled or disabled in firmware, or $null when it can't be determined.

    .DESCRIPTION
        WSL2 - and everything built on it here (Debian, Docker Desktop's WSL2 backend,
        Olivetin) - needs this even when both required Windows optional features are enabled;
        without it, WSL2 fails to start with error 0x80370102. Unlike the optional features,
        this is a firmware/BIOS-UEFI setting that can't be enabled from software, so callers
        should treat this as informational for warning the user, not something to silently
        "fix" - only a definite $false should block anything, since a $null (property missing
        on this OS build/environment, or the query timing out below) is not evidence
        virtualization is actually unavailable.

        Bounded to a few seconds via Invoke-WinUtilWithTimeout - WMI/CIM queries can
        occasionally hang (e.g. a corrupted WMI repository), and this is called synchronously
        on the UI thread by Resolve-WinUtilPrerequisites (it has to, to show its modal
        dialog), so a hang here would freeze the whole app rather than just delay a background
        operation. A timeout returns $null (same as any other "couldn't determine" case), not
        $false - it isn't evidence virtualization is disabled, just that this particular query
        didn't come back in time.
    #>
    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $null -ScriptBlock {
        try {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $cpu -or $null -eq $cpu.VirtualizationFirmwareEnabled) {
                return $null
            }
            return [bool]$cpu.VirtualizationFirmwareEnabled
        } catch {
            return $null
        }
    }
}

function Test-WinUtilWSLDistroInstalled {
    <#
    .SYNOPSIS
        Returns $true if the named WSL distro is already installed.

    .DESCRIPTION
        Bounded to a few seconds via Invoke-WinUtilWithTimeout - wsl.exe exists as a stub even
        before WSL is installed, and running it in that state can attempt to reach the
        Microsoft Store to auto-bootstrap, which can hang for a long time on a slow/absent
        network connection. Several callers of this run synchronously on the UI thread
        (Resolve-WinUtilPrerequisites has to, to show its modal dialog), so a hang here froze
        the whole app rather than just delaying a background operation.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $false -ArgumentList @($Distro) -ScriptBlock {
        param($Distro)
        try {
            $installed = & wsl -l -q 2>$null | ForEach-Object { $_.Trim().TrimEnd([char]0) } | Where-Object { $_ }
            return $installed -contains $Distro
        } catch {
            return $false
        }
    }
}

function Test-WinUtilWSLFeatureEnabled {
    <#
    .SYNOPSIS
        Returns $true only if WSL2 is actually usable - not just the base "Windows Subsystem
        for Linux" optional feature, but "VirtualMachinePlatform" too, and the WSL runtime
        itself.

    .DESCRIPTION
        WSL2 (unlike WSL1) runs on top of a lightweight VM, so it needs both
        Microsoft-Windows-Subsystem-Linux and VirtualMachinePlatform enabled - a system with
        only the first one turned on (e.g. an old manual WSL1 setup, or VirtualMachinePlatform
        disabled independently by policy or Windows Features) would still report "WSL is
        enabled" under a single-feature check while actually being unable to run a WSL2
        distro. Install-WinUtilFeatureWSL.ps1 already enables both correctly via
        "wsl --install" - this only affects detection, i.e. Show Installed Apps and
        prerequisite checks before installing anything that depends on WSL2.

        Also runs "wsl --status" and checks its exit code, not just the optional features -
        "wsl --uninstall" removes the WSL runtime without disabling the optional features, so
        the features alone would still say "Enabled" long after the runtime is actually gone
        (this was reported live: Show Installed Apps said WSL2 was installed, but "wsl --status"
        said "The Windows Subsystem for Linux is not installed" - confirmed on that same machine
        to exit with code 50). Any non-zero exit is treated as "not confidently usable," not just
        50 specifically, since the exact set of failure codes wsl.exe can return isn't fully
        known - the cost of an unnecessary restart prompt or redundant reinstall is far lower
        than silently trusting an absent/broken runtime as fine, which is the bug this fixes.

        Queries the optional features in one unfiltered call and filters the result locally,
        rather than two separate -FeatureName-filtered calls - Get-WindowsOptionalFeature is
        DISM-backed and each call can take several seconds regardless of how narrow the
        filter is, so two calls doubles that cost. "wsl --status" runs inside the same bounded
        call rather than a second one, for the same reason - one round-trip, not two.

        Bounded to a few seconds via Invoke-WinUtilWithTimeout on top of that - DISM/CBS can
        occasionally take far longer than normal (a slow or partially corrupted servicing
        state), and wsl.exe itself can hang trying to reach the Microsoft Store when WSL isn't
        installed. This matters more here than most places: Resolve-WinUtilPrerequisites calls
        this synchronously on the UI thread (it has to, to show its modal dialog), so a slow or
        hung call here froze the whole app rather than just delaying a background operation.

        Checks $sync.WSLRuntimeUninstalled first (set by Uninstall-WinUtilFeatureWSL, cleared by
        Install-WinUtilFeatureWSL) before even querying DISM/wsl.exe - a fast, always-correct
        short-circuit for the one case we can be certain about (we just uninstalled it
        ourselves, this session) without needing either external query at all. This only covers
        uninstalls done through WinUtil in the CURRENT app session though - the "wsl --status"
        check above is what actually covers every other case (a previous session, or WSL2
        removed outside WinUtil entirely), which the flag alone never could.
    #>
    if ($null -ne $sync -and $sync.ContainsKey("WSLRuntimeUninstalled") -and $sync.WSLRuntimeUninstalled) {
        return $false
    }

    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $false -ScriptBlock {
        try {
            $features = Get-WindowsOptionalFeature -Online -ErrorAction Stop
            $wslFeature = $features | Where-Object { $_.FeatureName -eq "Microsoft-Windows-Subsystem-Linux" }
            $vmPlatformFeature = $features | Where-Object { $_.FeatureName -eq "VirtualMachinePlatform" }
            if ($wslFeature.State -ne "Enabled" -or $vmPlatformFeature.State -ne "Enabled") {
                return $false
            }
        } catch {
            return $false
        }

        try {
            & wsl --status 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                return $false
            }
        } catch {
            return $false
        }

        return $true
    }
}

Function Uninstall-WinUtilFeatureWSL {
    <#
    .SYNOPSIS
        Uninstalls the WSL2 platform: after confirming with the user, stops and unregisters
        any distro(s) WinUtil's own catalog manages (installType "wslDistro") that are actually
        currently registered, then runs "wsl --uninstall".

    .DESCRIPTION
        No catalog entry currently declares installType "wslDistro" - Debian moved to a normal
        winget install (Debian.Debian) after "wsl --install -d Debian" was confirmed to hang
        waiting on its interactive first-run OOBE prompt, even from a genuinely interactive
        terminal, which switching install mechanisms couldn't fix. This unregister/confirm path
        (and the sibling Install-WinUtilWSLDistro.ps1/Uninstall-WinUtilWSLDistro.ps1) is left in
        place rather than removed, in case a future catalog entry needs it for a distro that
        isn't separately available via winget.

        Only ever unregisters distros declared in WinUtil's own catalog (installType
        "wslDistro") - never anything else that might be registered on this machine, since that
        data isn't ours to delete. Unregistering permanently deletes that distro's filesystem,
        so - unlike every other step here - this specifically asks for a Yes/No confirmation
        before doing it (via Invoke-WPFUIThreadWithResult, since this runs in the background
        install runspace, not the UI thread) rather than treating it as an implicit side effect of
        uninstalling WSL2. Declining leaves the distro registered (orphaned once the WSL runtime
        below is gone, but not deleted) - "wsl --uninstall" doesn't require every distro to be
        gone first; it removes the WSL runtime/app regardless.

        Does not disable the underlying Windows optional features (Microsoft-Windows-Subsystem-
        Linux, VirtualMachinePlatform) - "wsl --uninstall" doesn't touch those, and turning them
        off is a separate, more disruptive step (needs a restart) that isn't done here.

        Bounded via Invoke-WinUtilWithTimeout, not the few-second default used elsewhere for
        quick DISM/registry checks - wsl.exe can occasionally hang for reasons unrelated to this
        specific command (see Install-WinUtilWSLDistro.ps1 for a confirmed real case on the
        install side), and there's no reason to trust --shutdown/--uninstall are immune just
        because they aren't known to hit that exact case.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    $ownedDistros = @($sync.configs.applicationsHashtable.Values | Where-Object { $_.installType -eq "wslDistro" })
    $registeredOwnedDistros = @($ownedDistros | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.distro) -and (Test-WinUtilWSLDistroInstalled -Distro $_.distro)
    })

    if ($registeredOwnedDistros.Count -gt 0) {
        $distroNames = ($registeredOwnedDistros | ForEach-Object { $_.content }) -join ", "
        $confirmed = Invoke-WPFUIThreadWithResult -ScriptBlock {
            (Show-WinUtilMessage -Message "Uninstalling WSL2 will also permanently delete the following WSL distro(s) and all data inside them:`n - $distroNames`n`nDelete them now?" -Title "Confirm WSL distro deletion" -Button ([System.Windows.MessageBoxButton]::YesNo) -Icon "Warning") -eq [System.Windows.MessageBoxResult]::Yes
        }

        if ($confirmed) {
            Uninstall-WinUtilWSLDistro -Packages $registeredOwnedDistros
        } else {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Skipping deletion of $distroNames - declined. Left registered (will become orphaned, not deleted, once the WSL2 runtime below is uninstalled)."
        }
    }

    foreach ($package in $Packages) {
        $name = $package.content
        Write-WinUtilLog -Component "Package" -Message "Uninstalling WSL2 ($name)"

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 120 -DefaultValue $null -OnWaitingIntervalSeconds 20 -OnWaiting {
            param($elapsedSeconds)
            Write-WinUtilLog -Component "Package" -Message "Still uninstalling WSL2 ($($elapsedSeconds)s elapsed)."
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling WSL2 ($($elapsedSeconds)s elapsed)..."
        } -ScriptBlock {
            try {
                & wsl --shutdown 2>&1 | Out-Null
                return (& wsl --uninstall 2>&1 | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --uninstall did not finish within the expected time."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --uninstall completed with no console output)" })
        }
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: this removes the WSL runtime, not the underlying Windows optional features (Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform) - turn those off separately in Windows Features if you want WSL2 fully disabled."
        # The optional features stay "Enabled" per DISM even though the runtime is now gone
        # (see above) - flag this so Test-WinUtilWSLFeatureEnabled doesn't keep reporting
        # WSL2 as usable for the rest of this app session. Set unconditionally (not gated on
        # $output being non-null) - we attempted the uninstall regardless of whether it
        # finished within the timeout, and the safer assumption is "no longer trustworthy as
        # enabled" rather than risk the opposite mistake again.
        if ($null -ne $sync) { $sync.WSLRuntimeUninstalled = $true }
    }
}

Function Uninstall-WinUtilProgramDirect {
    <#
    .SYNOPSIS
        Uninstalls a "direct" install-type package, either via a declared uninstallCommand
        (a native PowerShell command string, for packages with a known safe uninstall) or by
        re-launching the same installer used to install it, when the installer itself detects
        an existing install and offers to uninstall (uninstallViaInstaller: true) - the
        correct approach for apps with no separate uninstaller, since we can't reliably infer
        everything a vendor's own installer cleans up.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content

        if (-not [string]::IsNullOrWhiteSpace($package.uninstallCommand)) {
            Write-WinUtilLog -Component "Package" -Message "Uninstalling $name"
            try {
                & ([scriptblock]::Create($package.uninstallCommand))
                Write-WinUtilLog -Component "Package" -Message "$name uninstalled."
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall ${name}: $_"
            }
            continue
        }

        if ($package.uninstallViaInstaller -and -not [string]::IsNullOrWhiteSpace($package.url)) {
            $url = $package.url
            $ext = [IO.Path]::GetExtension($url)
            if ([string]::IsNullOrEmpty($ext)) { $ext = ".exe" }
            $dest = Join-Path $env:TEMP "$name-uninstall$ext"

            Write-WinUtilLog -Component "Package" -Message "Downloading $name installer (for uninstall) from $url"
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to download ${name}: $_"
                continue
            }

            Write-WinUtilLog -Component "Package" -Message "Launching $name installer - it should detect the existing install and offer to uninstall. Stop $name first if it's running, then choose Uninstall in the window that opens. WinUtil will not wait for it to close."
            try {
                $proc = Start-Process -FilePath $dest -PassThru
                Set-WinUtilProcessForeground -Process $proc
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to launch uninstaller for ${name}: $_"
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name has no uninstallCommand or uninstallViaInstaller defined - not uninstalled."
    }
}

Function Uninstall-WinUtilStreamLinkManager {
    <#
    .SYNOPSIS
        Uninstalls Streaming Library Manager.

    .DESCRIPTION
        No uninstall is documented upstream for slm.bat. Since Install-WinUtilStreamLinkManager
        owns the entire install location (a fixed folder under LocalAppData, not something the
        user chose or put other data into), this can safely remove it outright: stop the
        process, unregister the logon scheduled task, delete the install directory.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    $taskName = "Streaming Library Manager"

    foreach ($package in $Packages) {
        $name = $package.content
        $installDir = Join-Path $env:LocalAppData "StreamLinkManager"

        Write-WinUtilLog -Component "Package" -Message "Uninstalling $name"
        try {
            Get-Process -Name "slm" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            & schtasks /delete /tn $taskName /f 2>$null | Out-Null

            if (Test-Path $installDir) {
                Remove-Item $installDir -Recurse -Force
            }

            Write-WinUtilLog -Component "Package" -Message "$name uninstalled."
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall ${name}: $_"
        }
    }
}

Function Uninstall-WinUtilWSLDistro {
    <#
    .SYNOPSIS
        Unregisters a WSL distro (e.g. Debian) - this permanently deletes its filesystem and
        all data inside it, not just "removes" it. Only ever call this for distros WinUtil's
        own catalog installed - never for an arbitrary/unknown distro, since that data isn't
        ours to delete.

    .DESCRIPTION
        Bounded via Invoke-WinUtilWithTimeout, not the few-second default used elsewhere for
        quick DISM/registry checks - deleting a distro's filesystem can take a little while, and
        wsl.exe itself can occasionally hang for unrelated reasons (see
        Install-WinUtilWSLDistro.ps1 for a confirmed real case on the install side; unregister
        isn't known to hit the same interactive first-run prompt, but there's no reason to trust
        it unconditionally either). Verifies success afterward via Test-WinUtilWSLDistroInstalled
        rather than trusting wsl.exe's own exit behavior, for the same reason a timeout here
        isn't necessarily a real failure.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $distro = $package.distro

        if ([string]::IsNullOrWhiteSpace($distro)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "WSL distro uninstall for $name is missing distro."
            continue
        }

        if (-not (Test-WinUtilWSLDistroInstalled -Distro $distro)) {
            Write-WinUtilLog -Component "Package" -Message "$name ($distro) is not registered - nothing to uninstall."
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Unregistering WSL distro $distro ($name) - this deletes its filesystem and data."

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 120 -DefaultValue $null -ArgumentList @($distro) -OnWaitingIntervalSeconds 20 -OnWaiting {
            param($elapsedSeconds)
            Write-WinUtilLog -Component "Package" -Message "Still unregistering WSL distro $distro ($($elapsedSeconds)s elapsed)."
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Unregistering $name ($($elapsedSeconds)s elapsed)..."
        } -ScriptBlock {
            param($distro)
            try {
                & wsl --terminate $distro 2>&1 | Out-Null
                return (& wsl --unregister $distro 2>&1 | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --unregister $distro did not finish within the expected time - checking whether it actually unregistered anyway."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --unregister $distro completed with no console output)" })
        }

        if (Test-WinUtilWSLDistroInstalled -Distro $distro) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$name ($distro) still appears registered after the unregister attempt."
        } else {
            Write-WinUtilLog -Component "Package" -Message "$name ($distro) is unregistered."
        }
    }
}

function Update-WinUtilSelections ($flatJson) {
    foreach ($cbkey in $flatJson) {

        $listName = switch -Regex ($cbkey) {
            '^WPFInstall' { 'selectedApps' }
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
            '^WPFFeature' { 'selectedFeatures' }
            '^WPFAppx'    { 'selectedAppx' }
        }

        $sync.$listName.Add($cbkey)
    }
}

function Write-WinUtilLog {
    <#

    .SYNOPSIS
        Writes a timestamped WinUtil log entry to the active session log.

    .PARAMETER Message
        The message to write.

    .PARAMETER Level
        The severity level for the log entry.

    .PARAMETER Component
        The WinUtil component producing the log entry.

    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$Component = "WinUtil"
    )

    try {
        $logPath = $null
        $transcriptPath = $null
        if ($null -ne $sync -and $sync.ContainsKey("logPath")) {
            $logPath = $sync.logPath
        }

        if ($null -ne $sync -and $sync.ContainsKey("transcriptPath")) {
            $transcriptPath = $sync.transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($transcriptPath)) {
            $logPath = $transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and $null -ne $sync -and $sync.ContainsKey("winutildir")) {
            $logDirectory = Join-Path $sync.winutildir "logs"
            $logPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            $sync.logPath = $logPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
            if ([string]::IsNullOrWhiteSpace($script:WinUtilLogPath)) {
                $logDirectory = Join-Path (Join-Path $env:LocalAppData "winutil") "logs"
                $script:WinUtilLogPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            }
            $logPath = $script:WinUtilLogPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath)) {
            return
        }

        $logDirectory = Split-Path -Path $logPath -Parent
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $line = "[$timestamp] [$Level] [$Component] $Message"

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and $logPath -eq $transcriptPath) {
            Write-Host $line
            return
        }

        try {
            Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch [System.IO.IOException] {
            Write-Host $line
        }
    } catch {
        Write-Warning "Unable to write WinUtil log entry: $($_.Exception.Message)"
    }
}

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
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 },
            [PSCustomObject]@{ Name = "Open";       Icon = [char]0xE8A7 }
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
                            Start-Process $appObject.link
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
                            if ($appObject.webui) {
                                $this.Tag = $appObject.webui
                                $this.ToolTip = "Open web interface`n$($appObject.webui)"
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
                                Start-Process $this.Tag
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


function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Milliseconds 100
        while ($sync.ProcessRunning) {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($sync.selectedTweaks.Count -gt 0) {
        Write-Host "Applying tweaks..."
        Invoke-WPFtweaksbutton
        BusyWait
    }

    if ($sync.selectedFeatures.Count -gt 0) {
        Write-Host "Applying features..."
        Invoke-WPFFeatureInstall
        BusyWait
    }

    if ($sync.selectedApps.Count -gt 0) {
        Write-Host "Installing applications..."
        Invoke-WPFInstall
        BusyWait
    }

    if ($sync.selectedAppx.Count -gt 0) {
        Write-Host "Removing AppX packages..."
        Invoke-WPFAppxRemoval
        BusyWait
    }

    Write-Host "Done."
}

function Invoke-WPFAppxInstall {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "An AppX process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "No AppX Package selected" -Title "Error" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX install for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing AppX install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 100)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $($app.Content) ($position/$totalPackages)" -Percent $startPercent
                }
                Write-Host "Installing $($app.Content)"
                Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId

                $completedPercent = [int](($position / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $($app.Content) ($position/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            Write-Host "================================="
            Write-Host "--   AppX Install Finished   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX install finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX install finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX install failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

function Invoke-WPFAppxRemoval {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "An AppX process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "No AppX Package selected" -Title "Error" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        $packageList = [System.Collections.Generic.List[string]]::new()

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX removal for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing AppX removal (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removing $($app.Content) ($position/$totalPackages)" -Percent $startPercent
                }

                if ($key -eq "WPFAppxMicrosoft_XboxGamingOverlay") {
                    # Making sure Game Bar isn't running
                    Write-WinUtilLog -Component "AppX" -Message "Stopping GameBarFTServer before removing Xbox Gaming Overlay."
                    Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue

                    # This stops annoying ms-gamebar popup when launching games.
                    Write-WinUtilLog -Component "AppX" -Message "Disabling Game DVR capture before removing Xbox Gaming Overlay."
                    Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0
                }

                if ($key -eq "WPFAppxMicrosoft_WindowsNotepad") {
                    Write-WinUtilLog -Component "AppX" -Message "Stopping dllhost before removing Notepad."
                    Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue
                }

                Write-Host "Removing $($app.Content)"
                Write-WinUtilLog -Component "AppX" -Message "Removing $($app.Content) ($($app.PackageId))."
                Remove-WinUtilAPPX -Name $app.PackageId
                $packageList.Add($app.PackageId)

                if ($key -eq "WPFAppxMSTeams") {
                    # Uninstalls Microsoft Teams Meeting Add-in for Microsoft Office
                    Write-WinUtilLog -Component "AppX" -Message "Uninstalling Microsoft Teams meeting add-in package."
                    Get-Package -Name "Microsoft Teams*" -ErrorAction SilentlyContinue | Uninstall-Package -Force
                }

                $completedPercent = [int](($position / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removed $($app.Content) ($position/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if ($packageList.Count -gt 0) {
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removing provisioned AppX packages" -Percent 90
                }
                Remove-WinUtilProvisionedAPPX -PackageList $packageList.ToArray()
            }

            Write-Host "================================="
            Write-Host "--   AppX Removal Finished   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX removal finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX removal finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX removal failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX removal failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }

    }
}

function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Chris Titus Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning -and -not $sync.Win11ISOProcessRunning) {
        Set-WinUtilTweaksProgressIndicator -Visible $false
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFAdvanced" {Invoke-WPFPresets "Advanced" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Enable}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFAppxRemoval" {Invoke-WPFTab "WPFTab6BT"}
        "WPFBackToTweaks" {Invoke-WPFTab "WPFTab2BT"}
        "WPFInstallSelectedAppx" {Invoke-WPFAppxInstall}
        "WPFRemoveSelectedAppx" {Invoke-WPFAppxRemoval}
        "WPFDefaultAppxSelection" {Invoke-WPFPresets "AppxDefault" -checkboxfilterpattern "WPFAppx*"}
        "WPFSelectAllAppx" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $true}
        }
        "WPFClearAppxSelection" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $false}
        }
        "WPFGetInstalledAppx" {
            $installedAppxPackages = Get-WinUtilInstalledAPPX
            foreach ($appx in $sync.configs.appxHashtable.GetEnumerator()) {
                if ($appx.Value.PackageId -in $installedAppxPackages) {
                    $sync.$($appx.Key).IsChecked = $true
                }
            }
        }
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
        "WPFMinimizeButton" {[Windows.SystemCommands]::MinimizeWindow($sync.Form)}
        "WPFMaximizeButton" {
            if ($sync.Form.WindowState -eq [Windows.WindowState]::Normal) {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            } else {
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            }
        }
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
    }
}

function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$Features.Count) }
        }

        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}

function Invoke-WPFFixesNetwork {
    netsh winsock reset
    netsh int ip reset
    Write-Host "Network Configuration has been Reset. Please restart your computer."
}

function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync

    Write-Host "================================="
    Write-Host "-- NTP Configuration Complete ---"
    Write-Host "================================="
}

function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Reset Windows Update "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}

function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}

function Invoke-WPFGetInstalled {
    <#
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager
    $operation = [Hashtable]::Synchronized(@{
        Checkboxes = @()
        Error = $null
    })
    $completeAction = [Action[hashtable, string]]{
        param(
            [hashtable]$completedOperation,
            [string]$completedCheckbox
        )
        try {
            if ($completedOperation.Error) {
                Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Get installed state failed: $($completedOperation.Error)"
                Write-Warning "Unable to get installed state: $($completedOperation.Error)"
                return
            }

            if ($completedCheckbox -eq "winget") {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    if (-not $sync.selectedApps.Contains($checkboxName)) {
                        $sync.selectedApps.Add($checkboxName)
                    }
                }
                Reset-WPFCheckBoxes -checkboxfilterpattern "WPFInstall*"
            } else {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    $sync.$checkboxName.ischecked = $True
                }
            }
        } finally {
            $sync.ProcessRunning = $false
            Set-WinUtilTaskbaritem -state "None"
        }
    }

    $sync.ProcessRunning = $true
    Set-WinUtilTaskbaritem -state "Indeterminate"
    try {
        Invoke-WPFRunspace -ParameterList @(
            ("managerPreference", $managerPreference),
            ("checkbox", $checkbox),
            ("operation", $operation),
            ("completeAction", $completeAction)
        ) -ScriptBlock {
            param (
                [string]$checkbox,
                [string]$managerPreference,
                [hashtable]$operation,
                [Action[hashtable, string]]$completeAction
            )
            try {
                if ($checkbox -eq "winget") {
                    switch ($managerPreference) {
                        "Choco" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox "choco"); break }
                        "Winget" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox); break }
                    }
                } elseif ($checkbox -eq "tweaks") {
                    $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox)
                }
            } catch {
                $operation.Error = $_.Exception.Message
            } finally {
                $sync.Form.Dispatcher.BeginInvoke($completeAction, [object[]]@($operation, $checkbox)) | Out-Null
            }
        }
    } catch {
        $operation.Error = $_.Exception.Message
        $completeAction.Invoke($operation, $checkbox)
    }
}

function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures + $sync.selectedAppx) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "No settings are selected to export. Please select at least one app, tweak, toggle, feature, or AppX package before exporting.",
                            "Nothing to Export", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://christitus.com/win) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "The selected file contains no settings to import. No changes have been made.",
                            "Empty Configuration", "OK", "Warning")
                        return
                    }

                    # Clear all existing selections before importing so the import replaces
                    # the current state rather than merging with it
                    $sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedApps = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()

                    Update-WinUtilSelections -flatJson $flattenedJson

                    if ($sync.Form) {
                        Reset-WPFCheckBoxes -doToggles $true
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}

function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [PSObject[]]$PackagesToInstall = $($sync.selectedApps | Foreach-Object {
            $pkg = $sync.configs.applicationsHashtable.$_
            if ($pkg) { $pkg | Add-Member -NotePropertyName Key -NotePropertyValue ($_ -replace '^WPFInstall', '') -PassThru -Force }
        })
    )


    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade."
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    # Prerequisite checks and value prompts show modal dialogs, so they must run here on the
    # UI thread - before the selection is handed off to the background install runspace.
    $PackagesToInstall = Resolve-WinUtilPrerequisites -PackagesToInstall $PackagesToInstall

    # Everything can legitimately end up dropped here (e.g. a declined or blocked prerequisite),
    # so check before the next step rather than after - Resolve-WinUtilPackagePrompts still
    # requires a non-empty array by design, since it isn't meant to be called with nothing to do.
    if ($PackagesToInstall.Count -eq 0) {
        Write-WinUtilLog -Component "Install" -Message "Nothing left to install after prerequisite resolution."
        return
    }

    $PackagesToInstall = Resolve-WinUtilPackagePrompts -PackagesToInstall $PackagesToInstall

    if ($PackagesToInstall.Count -eq 0) {
        Write-WinUtilLog -Component "Install" -Message "Nothing left to install after prompt resolution."
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Install" -Message "Install requested for $(@($PackagesToInstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToInstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Install" -Message "Install selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $packagesDirect = $packagesSorted['Direct']
        $packagesGithub = $packagesSorted['Github']
        $packagesNpm = $packagesSorted['Npm']
        $packagesWslFeature = $packagesSorted['WslFeature']
        $packagesWslDistro = $packagesSorted['WslDistro']
        $packagesWslCommand = $packagesSorted['WslCommand']
        $packagesStreamLinkManager = $packagesSorted['StreamLinkManager']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count + @($packagesDirect).Count + @($packagesGithub).Count + @($packagesNpm).Count + @($packagesWslFeature).Count + @($packagesWslDistro).Count + @($packagesWslCommand).Count + @($packagesStreamLinkManager).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        # winget/choco IDs actually installed/uninstalled don't carry the friendly display name -
        # this maps back to it (falling back to the raw ID) for the failure summary below.
        $packageNameById = @{}
        # Same idea, for winget/choco packages that declare a postInstallCommand (e.g. launching
        # an app once so its first-run setup starts right away) - Install-WinUtilProgramWinget/
        # Install-WinUtilProgramChoco only deal in bare ID strings, not full package objects, so
        # this is how the install loops below find the command to run after a given ID installs
        # successfully. A package could be keyed under either ID depending on which manager
        # preference actually installed it (e.g. Docker Desktop declares both), so both get
        # indexed regardless of $ManagerPreference.
        $postInstallCommandById = @{}
        foreach ($p in $PackagesToInstall) {
            if ($p.winget -and $p.winget -ne "na") { $packageNameById[$p.winget -replace '^msstore:', ''] = $p.content }
            if ($p.choco -and $p.choco -ne "na") { $packageNameById[$p.choco] = $p.content }
            if (-not [string]::IsNullOrWhiteSpace($p.postInstallCommand)) {
                if ($p.winget -and $p.winget -ne "na") { $postInstallCommandById[$p.winget -replace '^msstore:', ''] = $p.postInstallCommand }
                if ($p.choco -and $p.choco -ne "na") { $postInstallCommandById[$p.choco] = $p.postInstallCommand }
            }
        }
        $failedPackages = [System.Collections.Generic.List[string]]::new()
        Write-WinUtilLog -Component "Install" -Message "Install package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count), direct=$(@($packagesDirect).Count), github=$(@($packagesGithub).Count), npm=$(@($packagesNpm).Count), wslFeature=$(@($packagesWslFeature).Count), wslDistro=$(@($packagesWslDistro).Count), wslCommand=$(@($packagesWslCommand).Count), streamLinkManager=$(@($packagesStreamLinkManager).Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            # WSL2/Debian go first, ahead of winget/choco - Docker Desktop (winget) requires
            # WSL2, and previously ran before it was even enabled, since winget/choco installed
            # unconditionally first and the WSL feature/distro buckets only ran afterward as
            # part of the general bucket loop below.
            foreach ($installBucket in @(
                @{ Packages = $packagesWslFeature; Label = "WSL2 feature"; Installer = { param($pkgs) Install-WinUtilFeatureWSL -Packages $pkgs } },
                @{ Packages = $packagesWslDistro; Label = "WSL distro"; Installer = { param($pkgs) Install-WinUtilWSLDistro -Packages $pkgs } }
            )) {
                # @($null).Count is 1, not 0 - filtering out falsy entries first means a null or
                # missing bucket is correctly treated as empty here, instead of falling through
                # to the installer call below with $null and crashing on its Mandatory
                # [object[]] parameter ("Cannot bind argument ... because it is null").
                $bucketPackages = @($installBucket.Packages | Where-Object { $_ })
                if ($bucketPackages.Count -eq 0) { continue }

                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $($installBucket.Label) packages ($position/$totalPackages)" -Percent $startPercent
                }

                & $installBucket.Installer $bucketPackages

                $completedPackages += $bucketPackages.Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $($installBucket.Label) packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Install-WinUtilWinget
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    $installResults = Install-WinUtilProgramWinget -Action Install -Programs @($program)
                    foreach ($r in $installResults) {
                        if (-not $r.Success) {
                            $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                        } elseif ($postInstallCommandById.ContainsKey($r.Program)) {
                            $postInstallName = if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }
                            Write-WinUtilLog -Component "Install" -Message "Running post-install step for $postInstallName`: $($postInstallCommandById[$r.Program])"
                            try {
                                & ([scriptblock]::Create($postInstallCommandById[$r.Program]))
                                Write-WinUtilLog -Component "Install" -Message "$postInstallName post-install step completed"
                            } catch {
                                Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Post-install step failed for ${postInstallName}: $_"
                            }
                        }
                    }
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilChoco
                $installResults = Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
                foreach ($r in $installResults) {
                    if (-not $r.Success) {
                        $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                    } elseif ($postInstallCommandById.ContainsKey($r.Program)) {
                        $postInstallName = if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }
                        Write-WinUtilLog -Component "Install" -Message "Running post-install step for $postInstallName`: $($postInstallCommandById[$r.Program])"
                        try {
                            & ([scriptblock]::Create($postInstallCommandById[$r.Program]))
                            Write-WinUtilLog -Component "Install" -Message "$postInstallName post-install step completed"
                        } catch {
                            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Post-install step failed for ${postInstallName}: $_"
                        }
                    }
                }
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            foreach ($installBucket in @(
                @{ Packages = $packagesDirect; Label = "direct-download"; Installer = { param($pkgs) Install-WinUtilProgramDirect -Packages $pkgs } },
                @{ Packages = $packagesGithub; Label = "GitHub release"; Installer = { param($pkgs) Install-WinUtilProgramGithub -Packages $pkgs } },
                @{ Packages = $packagesNpm; Label = "npm"; Installer = { param($pkgs) Install-WinUtilProgramNpm -Packages $pkgs } },
                @{ Packages = $packagesWslCommand; Label = "WSL command"; Installer = { param($pkgs) Install-WinUtilWSLCommand -Packages $pkgs } },
                @{ Packages = $packagesStreamLinkManager; Label = "Streaming Library Manager"; Installer = { param($pkgs) Install-WinUtilStreamLinkManager -Packages $pkgs } }
            )) {
                # @($null).Count is 1, not 0 - see the WSL bucket loop above for why this matters.
                $bucketPackages = @($installBucket.Packages | Where-Object { $_ })
                if ($bucketPackages.Count -eq 0) { continue }

                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $($installBucket.Label) packages ($position/$totalPackages)" -Percent $startPercent
                }

                & $installBucket.Installer $bucketPackages

                $completedPackages += $bucketPackages.Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $($installBucket.Label) packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            if ($failedPackages.Count -gt 0) {
                $failedList = $failedPackages -join "`n - "
                Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Install workflow completed with failures: $($failedPackages -join ', ')"
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished with errors" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock {
                        Set-WinUtilTaskbaritem -state "None" -overlay "warning"
                        Show-WinUtilMessage -Message "These failed to install - check the log for details:`n - $failedList" -Title "Some installs failed" -Button "OK" -Icon "Warning"
                    }
                }
            } else {
                Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
                }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Install workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }
    }
}

function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList '-NoExit winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
    }
}

function Invoke-WPFOOSU {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "Another process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $downloadPath = Join-Path $sync.winutildir "ooshutup10.exe"
    $sync.ProcessRunning = $true

    Invoke-WPFRunspace -ParameterList @(,("downloadPath", $downloadPath)) -ScriptBlock {
        param($downloadPath)

        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "OOSU" -Message "Downloading O&O ShutUp10++."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ (0%)" -Percent 0
            }

            Save-WinUtilFile -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -DestinationPath $downloadPath -ProgressCallback {
                param($percent)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ ($percent%)" -Percent $percent
                }
            }

            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Launching O&O ShutUp10++" -Percent 100
            }
            Start-Process -FilePath $downloadPath

            Write-WinUtilLog -Component "OOSU" -Message "O&O ShutUp10++ launched."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ launched" -Percent 100
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "OOSU" -Message "O&O ShutUp10++ download failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ download failed" -Percent 100
            }
            Write-Error "Couldn't download O&O ShutUp10. Please make sure you have an active Internet connection."
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

function Invoke-WPFPanelAutologin {
    Invoke-WebRequest -Uri https://live.sysinternals.com/Autologon.exe -OutFile "$winutildir\autologin.exe"
    Start-Process -FilePath "$winutildir\autologin.exe" -ArgumentList /accepteula
}

function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}

function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFAppx*" { $sync.selectedAppx = [System.Collections.Generic.List[string]]::new() }
        "WPFFeature*" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle*" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}

function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    [OutputType([System.IAsyncResult])]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    if (-not ("WinUtilRunspaceCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class WinUtilRunspaceCleanupState
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilRunspaceCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilRunspaceCleanupState;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
        }
    }
}
"@
    }

    Initialize-WinUtilRunspacePool | Out-Null

    # Create a PowerShell instance
    $powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    [void]$powershell.AddScript($ScriptBlock)
    [void]$powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        [void]$powershell.AddParameter($parameter[0], $parameter[1])
    }

    $powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $handle = $powershell.BeginInvoke()

    $cleanupState = [WinUtilRunspaceCleanupState]::new()
    $cleanupState.PowerShell = $powershell
    $cleanupState.Handle = $handle
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject($handle.AsyncWaitHandle, [WinUtilRunspaceCleanup]::Callback, $cleanupState, -1, $true) | Out-Null

    # Return the handle
    return $handle
}

function Invoke-WPFSelectedCheckboxesUpdate ($type, $checkboxName) {
    $listName = switch -Regex ($checkboxName) {
        '^WPFInstall' { 'selectedApps' }
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
        '^WPFFeature' { 'selectedFeatures' }
        '^WPFAppx'    { 'selectedAppx' }
    }

    $selectionChanged = $false
    if ($type -eq "Add") {
        if (-not $sync.$listName.Contains($checkboxName)) {
            $sync.$listName.Add($checkboxName)
            $selectionChanged = $true
        }
    } else {
        $selectionChanged = $sync.$listName.Remove($checkboxName)
    }

    # Reset-WPFCheckBoxes sets this while bulk-toggling many checkboxes at once (e.g. after a
    # "Show Installed Apps" scan) - it does its own single rebuild afterward, so rebuilding here
    # on every individual checkbox change during that loop would be pure O(n^2) wasted work.
    if ($listName -eq "selectedApps" -and $selectionChanged -and -not $sync.SuppressSelectedAppsMenuRebuild) {
        $sync.WPFselectedAppsButton.Content = "Selected Apps: $($sync.selectedApps.Count)"
        $sync.selectedAppsstackPanel.Children.Clear()
        $sync.selectedApps | Sort-Object | ForEach-Object {
            Add-SelectedAppsMenuItem -name $sync.configs.applicationsHashtable.$_.Content -key $_
        }
    }
}

function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}

function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}

function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    $sync.$tabNav.Items[$tabNumber].IsSelected = $true
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header
    Initialize-WinUtilTabContent -TabName $sync.currentTab

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Tweaks") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "AppX") {
        # Reset AppX tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Install is the only tab, so the search bar is always shown
    $sync.SearchBar.Visibility = "Visible"
    $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
    if ($searchIcon) {
        $searchIcon.Visibility = "Visible"
    }
}

function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}

function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton] Install process is currently running."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0
  Write-WinUtilLog -Component "Tweaks" -Message "Tweaks requested: $(@($Tweaks).Count) selected tweak(s), DNS provider: $dnsProvider"

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "Please check the tweaks you wish to perform."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Creating restore point" -Percent 0
    Write-WinUtilLog -Component "Tweaks" -Message "Creating restore point before applying selected tweaks."
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "================================="
      Write-Host "--     Tweaks are Finished    ---"
      Write-Host "================================="
      Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed after restore point."
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    if ($dnsProvider -ne "Default") {
      Set-WinUtilDNS -DNSProvider $dnsProvider
    }

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Applying $($tweaks[$i]) ($($completedSteps + 1)/$totalSteps)" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed."
  }
}

function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes, notes last) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    'Note' { 3 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                            # Skip applying tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtilTweaks $Sender.name
                            }
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                            # Skip undoing tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            }
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $toggleButton.Name) {
                            $toggleButton.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($toggleButton.Name) | Out-Null
                        }
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $button.Name) {
                            $button.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($button.Name) | Out-Null
                        }
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)
                            $radioButtonGroups[$entryInfo.GroupName] = $groupStackPanel

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    "Note" {
                        $textBlock = New-Object Windows.Controls.TextBlock
                        $textBlock.TextWrapping = "Wrap"
                        $textBlock.Margin = "5,5,5,5"
                        $textBlock.UseLayoutRounding = $true

                        $bulletBadge = [Windows.Documents.InlineUIContainer]::new((New-WinUtilFossBadge -Size 18 -Round))
                        $bulletBadge.BaselineAlignment = [Windows.BaselineAlignment]::Center

                        $textRun = New-Object Windows.Documents.Run
                        $textRun.Text = " $($entryInfo.Content)"
                        $textRun.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $textRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))

                        $textBlock.Inlines.Add($bulletBadge)
                        $textBlock.Inlines.Add($textRun)

                        $itemsControl.Items.Add($textBlock) | Out-Null
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $checkBox

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Start-Process $Sender.ToolTip -ErrorAction Stop
                            })

                            $updateLinkMargin = {
                                [System.Object]$Sender = $args[0]
                                $linkedCheckBox = $Sender.Tag
                                $MarginTopBase = if ($linkedCheckBox) { $linkedCheckBox.Margin.Top } else { 0 }
                                $Sender.Margin = New-Object Windows.Thickness(
                                    [math]::Round($Sender.FontSize * 0.5),
                                    ($MarginTopBase - [math]::Round($Sender.FontSize / 2)),
                                    0, 0
                                )
                            }
                            $textBlock.Add_Loaded($updateLinkMargin)
                            $fontSizeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
                                [Windows.Controls.Control]::FontSizeProperty,
                                [Windows.Controls.TextBlock]
                            )
                            $fontSizeDescriptor.AddValueChanged($textBlock, $updateLinkMargin)

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                        })
                    }
                }
            }
        }
    }
}

function Invoke-WPFUIThread ($ScriptBlock) {
    <#
    .SYNOPSIS
        Runs a scriptblock synchronously on the UI thread. Void - see
        Invoke-WPFUIThreadWithResult if a caller needs the scriptblock's return value.

    .DESCRIPTION
        Deliberately cast to Action, not Func[object] - a version of this cast to Func[object]
        was tried and reverted. The problem: dozens of call sites across the codebase invoke
        this as a bare, uncaptured statement in the middle of a function, well before that
        function's own final `return`. Under Action, PowerShell discards whatever the scriptblock
        produces, so those bare calls are harmless. Under Func[object], each one instead adds its
        result to the *enclosing function's* own output stream - e.g. Get-WinUtilSelectedPackages
        calls this near the top to update the taskbar icon, and its actual return value (a
        hashtable) got silently wrapped into a 2-element array alongside that stray value,
        so `$packagesSorted['Winget']` on the caller's side returned nothing. That is a real
        production bug this shipped as (empty/lost package buckets on every install), not a
        theoretical risk - Pester never caught it because Invoke-WPFUIThread is mocked out in
        nearly every test file, so the return-stream interaction with real caller code was never
        exercised.
    #>
    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}

function Invoke-WPFUIThreadWithResult ($ScriptBlock) {
    <#
    .SYNOPSIS
        Runs a scriptblock synchronously on the UI thread and returns its result.

    .DESCRIPTION
        A separate function from Invoke-WPFUIThread, not a shared implementation switching on a
        parameter - the two must never be interchangeable at existing call sites. Invoke-
        WPFUIThread is called as a bare, uncaptured statement in dozens of places throughout the
        codebase, often mid-function rather than as the last statement; casting that shared
        Dispatcher.Invoke to Func[object] instead of Action made every one of those bare calls
        inject its result into the *enclosing function's* own return value once collected by its
        caller - a real shipped bug (see Invoke-WPFUIThread's own comment for the concrete
        failure). Use this only where the return value is actually consumed, e.g. a background
        runspace showing a modal Yes/No confirmation and needing the answer back.
    #>
    $sync.form.Dispatcher.Invoke([Func[object]]$ScriptBlock)
}

function Invoke-WPFUltimatePerformance ([switch]$Enable) {
    if ($Enable) {
        powercfg /setactive (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Select-String -Pattern '[A-Fa-f0-9-]{36}').Matches.Value
        [System.Windows.MessageBox]::Show("Ultimate Power Plan plan installed and activated.","Success","OK","Information")
    } else {
        powercfg /restoredefaultschemes
        [System.Windows.MessageBox]::Show("Power Plan was reset to defaults.","Success","OK","Information")
    }
}

function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Please check the tweaks you wish to undo."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks requested: $(@($tweaks).Count) selected tweak(s)."
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Undoing $($tweaks[$i]) ($($i + 1)/$($tweaks.Count))" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Undo Tweaks Finished" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks workflow completed."

    }
}

function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] Install process is currently running"
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to uninstall"
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $ButtonType = "YesNo"
    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = ("This will uninstall the following applications: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = "Information"

    # Unregistering a WSL distro permanently deletes its filesystem, not just "removes" it -
    # worth calling out explicitly here rather than folding it into the generic app list above.
    $wslDataLossPackages = @($PackagesToUninstall | Where-Object { $_.installType -eq "wslFeature" -or $_.installType -eq "wslDistro" })
    if ($wslDataLossPackages.Count -gt 0) {
        $Messageboxbody += "`nUninstalling WSL2 and/or a WSL distro permanently deletes that distro's filesystem and all data inside it - this cannot be undone."
    }

    $confirm = Show-WinUtilMessage -Message $Messageboxbody -Title $MessageboxTitle -Button $ButtonType -Icon $MessageIcon

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall requested for $(@($PackagesToUninstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToUninstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $packagesNpm = $packagesSorted['Npm']
        $packagesStreamLinkManager = $packagesSorted['StreamLinkManager']

        # Packages whose uninstall isn't automated - direct/WSL-command packages with no
        # declared uninstallCommand (or, for direct, no uninstallViaInstaller either), plus
        # github (arbitrary third-party installers with no known uninstaller).
        $unsupported = [System.Collections.Generic.List[string]]::new()
        $packagesDirect = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['Direct'])) {
            if ($p -and (-not [string]::IsNullOrWhiteSpace($p.uninstallCommand) -or $p.uninstallViaInstaller)) {
                $packagesDirect.Add($p)
            } elseif ($p) {
                $unsupported.Add($p.content)
            }
        }
        $packagesWslCommand = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslCommand'])) {
            if ($p -and -not [string]::IsNullOrWhiteSpace($p.uninstallCommand)) {
                $packagesWslCommand.Add($p)
            } elseif ($p) {
                $unsupported.Add($p.content)
            }
        }
        foreach ($p in @($packagesSorted['Github'])) { if ($p) { $unsupported.Add($p.content) } }
        $packagesWslDistro = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslDistro'])) { if ($p) { $packagesWslDistro.Add($p) } }
        $packagesWslFeature = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslFeature'])) { if ($p) { $packagesWslFeature.Add($p) } }

        $totalPackages = [Math]::Max(1, (@($packagesWinget).Count + @($packagesChoco).Count + @($packagesNpm).Count + @($packagesDirect).Count + @($packagesWslCommand).Count + @($packagesStreamLinkManager).Count + @($packagesWslDistro).Count + @($packagesWslFeature).Count))
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        # winget/choco IDs actually uninstalled don't carry the friendly display name - this maps
        # back to it (falling back to the raw ID) for the failure summary below.
        $packageNameById = @{}
        foreach ($p in $PackagesToUninstall) {
            if ($p.winget -and $p.winget -ne "na") { $packageNameById[$p.winget -replace '^msstore:', ''] = $p.content }
            if ($p.choco -and $p.choco -ne "na") { $packageNameById[$p.choco] = $p.content }
        }
        $failedPackages = [System.Collections.Generic.List[string]]::new()
        Write-WinUtilLog -Component "Uninstall" -Message "Uninstall package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count), npm=$(@($packagesNpm).Count), direct=$(@($packagesDirect).Count), wslCommand=$(@($packagesWslCommand).Count), streamLinkManager=$(@($packagesStreamLinkManager).Count), wslDistro=$(@($packagesWslDistro).Count), wslFeature=$(@($packagesWslFeature).Count), unsupported=$($unsupported.Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app uninstall (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if ($packagesWinget -contains "Microsoft.Edge") {
                New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force
            }

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    $uninstallResults = Install-WinUtilProgramWinget -Action Uninstall -Programs @($program)
                    foreach ($r in $uninstallResults) {
                        if (-not $r.Success) {
                            $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                        }
                    }
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                $uninstallResults = Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
                foreach ($r in $uninstallResults) {
                    if (-not $r.Success) {
                        $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                    }
                }
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            if ($packagesNpm.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling npm packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilProgramNpm -Action Uninstall -Packages $packagesNpm
                $completedPackages += @($packagesNpm).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled npm packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            if ($packagesDirect.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling direct-install packages ($position/$totalPackages)" -Percent $startPercent
                }

                Uninstall-WinUtilProgramDirect -Packages $packagesDirect
                $completedPackages += @($packagesDirect).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled direct-install packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            if ($packagesWslCommand.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling WSL command packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilWSLCommand -Action Uninstall -Packages $packagesWslCommand
                $completedPackages += @($packagesWslCommand).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled WSL command packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if ($packagesStreamLinkManager.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling Streaming Library Manager ($position/$totalPackages)" -Percent $startPercent
                }

                Uninstall-WinUtilStreamLinkManager -Packages $packagesStreamLinkManager
                $completedPackages += @($packagesStreamLinkManager).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled Streaming Library Manager ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            # Distro before feature - Uninstall-WinUtilFeatureWSL also unregisters WinUtil's own
            # distro(s) itself, so running the distro bucket first just means that work is
            # already done (and skipped as a no-op) by the time the feature bucket reaches it.
            foreach ($uninstallBucket in @(
                @{ Packages = $packagesWslDistro; Label = "WSL distro"; Uninstaller = { param($pkgs) Uninstall-WinUtilWSLDistro -Packages $pkgs } },
                @{ Packages = $packagesWslFeature; Label = "WSL2 feature"; Uninstaller = { param($pkgs) Uninstall-WinUtilFeatureWSL -Packages $pkgs } }
            )) {
                # @($null).Count is 1, not 0 - filtering out falsy entries first means a null or
                # missing bucket is correctly treated as empty here, instead of falling through
                # to the uninstaller call below with $null and crashing on its Mandatory
                # [object[]] parameter ("Cannot bind argument ... because it is null").
                $bucketPackages = @($uninstallBucket.Packages | Where-Object { $_ })
                if ($bucketPackages.Count -eq 0) { continue }

                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $($uninstallBucket.Label) packages ($position/$totalPackages)" -Percent $startPercent
                }

                & $uninstallBucket.Uninstaller $bucketPackages

                $completedPackages += $bucketPackages.Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $($uninstallBucket.Label) packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if ($unsupported.Count -gt 0) {
                $unsupportedList = $unsupported -join "`n - "
                Write-WinUtilLog -Level "WARN" -Component "Uninstall" -Message "Not uninstalled (no automatic uninstall available): $($unsupported -join ', ')"
                if ($hasUI) {
                    Invoke-WPFUIThread -ScriptBlock {
                        Show-WinUtilMessage -Message "These weren't uninstalled - there's no automatic uninstall for them yet, remove manually if needed:`n - $unsupportedList" -Title "Some apps were skipped" -Button "OK" -Icon "Warning"
                    }
                }
            }

            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            if ($failedPackages.Count -gt 0) {
                $failedList = $failedPackages -join "`n - "
                Write-WinUtilLog -Level "WARN" -Component "Uninstall" -Message "Uninstall workflow completed with failures: $($failedPackages -join ', ')"
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall finished with errors" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock {
                        Set-WinUtilTaskbaritem -state "None" -overlay "warning"
                        Show-WinUtilMessage -Message "These failed to uninstall - check the log for details:`n - $failedList" -Title "Some uninstalls failed" -Button "OK" -Icon "Warning"
                    }
                }
            } else {
                Write-WinUtilLog -Component "Uninstall" -Message "Uninstall workflow completed."
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall finished" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
                }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Uninstall" -Message "Uninstall workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }

    }
}

function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    Write-WinUtilLog -Component "Updates" -Message "Resetting Windows Update settings to default."

    Write-Host "Removing Windows Update settings managed by WinUtil..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Removing Windows Update registry values managed by WinUtil."

    $registryValues = @(
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Names = @("NoAutoUpdate", "AUOptions", "NoAutoRebootWithLoggedOnUsers", "AUPowerManagement")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Names = @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
            Names = @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
            Names = @("PreventDeviceMetadataFromNetwork")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
            Names = @("DontPromptForWindowsUpdate", "DontSearchWindowsUpdate", "DriverUpdateWizardWuSearchEnabled")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
            Names = @("DODownloadMode")
        }
    )

    foreach ($registryEntry in $registryValues) {
        foreach ($valueName in $registryEntry.Names) {
            Remove-ItemProperty -Path $registryEntry.Path -Name $valueName -ErrorAction SilentlyContinue
        }
    }

    $explorerPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $settingsPageVisibility = (Get-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($settingsPageVisibility -eq "hide:windowsupdate") {
        Write-Host "Removing WinUtil's legacy Windows Update page restriction..."
        Write-WinUtilLog -Component "Updates" -Message "Removing the legacy Windows Update settings page restriction."
        Remove-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue
    }

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update service startup types."

    Write-Host "Restored BITS to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring BITS service to Manual."
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring wuauserv service to Manual."
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic."
    Write-WinUtilLog -Component "Updates" -Message "Starting UsoSvc service and restoring startup type to Automatic."
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Enabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update default workflow completed. Restart required."
}

function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $confirmation = Show-WinUtilMessage `
        -Message "Disabling Windows Update stops update services, disables scheduled tasks, and clears downloaded update files. Security updates will not be installed until defaults are restored. Continue?" `
        -Title "Disable Windows Update?" `
        -Button "YesNo" `
        -Icon "Warning"

    if ($confirmation -ne "Yes") {
        Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow cancelled."
        return
    }

    Write-WinUtilLog -Component "Updates" -Message "Disabling Windows Update settings."

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Configuring Windows Update registry policy values for disable mode."
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    foreach ($serviceName in @("BITS", "wuauserv", "UsoSvc")) {
        Write-Host "Stopping and disabling $serviceName service."
        Write-WinUtilLog -Component "Updates" -Message "Stopping and disabling $serviceName service."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled
    }

    Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleared SoftwareDistribution folder."
    Write-WinUtilLog -Component "Updates" -Message "Cleared SoftwareDistribution folder."

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Disabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "--- Windows Update Is Disabled ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow completed. Restart required."
}

function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Defers feature updates for 365 days
        3. Defers quality updates for 4 days
        4. Prevents automatic restarts while a user is signed in

    #>

    Write-Host "Disabling driver offering through Windows Update..."
    Write-WinUtilLog -Component "Updates" -Message "Applying recommended Windows Update settings."
    Write-WinUtilLog -Component "Updates" -Message "Disabling driver offering through Windows Update."

    $windowsUpdatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $automaticUpdatePolicyPath = Join-Path $windowsUpdatePolicyPath "AU"

    Write-Host "Restoring Windows Update availability..."
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update services and scheduled tasks before applying recommended settings."

    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -ErrorAction SilentlyContinue

    Set-Service -Name BITS -StartupType Manual
    Set-Service -Name wuauserv -StartupType Manual
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path $windowsUpdatePolicyPath -Force
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Deferring feature updates by 365 days and quality updates by 4 days..."
    Write-WinUtilLog -Component "Updates" -Message "Deferring feature updates by 365 days and quality updates by 4 days."

    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    $legacySettingsPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    foreach ($legacyValue in @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")) {
        Remove-ItemProperty -Path $legacySettingsPath -Name $legacyValue -ErrorAction SilentlyContinue
    }

    Write-Host "Preventing automatic restarts while users are signed in..."
    Write-WinUtilLog -Component "Updates" -Message "Configuring scheduled automatic updates without restarting while users are signed in."

    New-Item -Path $automaticUpdatePolicyPath -Force
    # NoAutoRebootWithLoggedOnUsers only applies when automatic updates use option 4.
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUOptions" -Type DWord -Value 4
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Updates" -Message "Recommended Windows Update settings workflow completed."
}

$sync.configs.applications = @'
{
  "WPFInstallchocolatey": {
    "category": "Foundational",
    "content": "Chocolatey",
    "description": "Command-line package manager for Windows, built on NuGet - installing this lets WinUtil install other apps via choco when that's your preferred package manager.",
    "link": "https://chocolatey.org",
    "icon": "https://raw.githubusercontent.com/chocolatey/choco/master/docs/logo/chocolateyicon.png",
    "handle": "Chocolatey Software, Inc.",
    "winget": "Chocolatey.Chocolatey",
    "foss": true
  },
  "WPFInstallunigetui": {
    "category": "Foundational",
    "choco": "wingetui",
    "content": "UniGetUI",
    "description": "Graphical interface for managing packages across WinGet, Chocolatey, Scoop, and other package managers from one screen. Formerly WingetUI.",
    "link": "https://devolutions.net/unigetui/",
    "icon": "https://raw.githubusercontent.com/Devolutions/UniGetUI/main/media/icon.png",
    "handle": "Devolutions",
    "winget": "Devolutions.UniGetUI",
    "foss": true
  },
  "WPFInstallpowershell7": {
    "category": "Foundational",
    "content": "PowerShell 7",
    "description": "The current, cross-platform PowerShell (pwsh) - installs alongside Windows PowerShell 5.1 rather than replacing it. Some things this app has to work around only happen under 5.1 (e.g. Set-Content -Encoding UTF8 silently adding a byte-order-mark that 7+ doesn't add), so it's worth having available.",
    "link": "https://github.com/PowerShell/PowerShell",
    "icon": "https://raw.githubusercontent.com/PowerShell/PowerShell/master/assets/Powershell_256.png",
    "handle": "Microsoft Corporation",
    "winget": "Microsoft.PowerShell",
    "foss": true
  },
  "WPFInstallwindowsterminal": {
    "category": "Foundational",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal",
    "description": "Modern terminal application for command-line shells like PowerShell and WSL, with tabs and profiles.",
    "link": "https://aka.ms/terminal",
    "icon": "https://raw.githubusercontent.com/microsoft/terminal/main/res/terminal/images/Square44x44Logo.targetsize-256_altform-unplated.png",
    "handle": "Microsoft",
    "winget": "Microsoft.WindowsTerminal",
    "foss": true
  },
  "WPFInstalltailscale": {
    "category": "Foundational",
    "choco": "tailscale",
    "content": "Tailscale",
    "description": "Zero-config mesh VPN built on WireGuard, useful for reaching your Channels DVR server remotely without port forwarding.",
    "link": "https://tailscale.com",
    "handle": "Tailscale Inc.",
    "winget": "Tailscale.Tailscale",
    "foss": true
  },
  "WPFInstalldockerdesktop": {
    "category": "Foundational",
    "choco": "docker-desktop",
    "content": "Docker Desktop",
    "description": "Docker Desktop is required to run several Channels DVR ecosystem add-ons, including Olivetin (EZ-Start). Opens automatically after installing, since the Docker engine doesn't actually start until you launch it at least once.",
    "link": "https://www.docker.com/products/docker-desktop/",
    "handle": "Docker, Inc.",
    "winget": "Docker.DockerDesktop",
    "requires": [
      "wsl2",
      "debian"
    ],
    "postInstallCommand": "$dockerExe = Join-Path $env:ProgramFiles 'Docker\\Docker\\Docker Desktop.exe'; if (Test-Path $dockerExe) { Start-Process $dockerExe } else { Write-WinUtilLog -Level 'WARN' -Component 'Package' -Message 'Docker Desktop executable not found at the expected location - launch it manually from the Start Menu.' }",
    "foss": false
  },
  "WPFInstallnodejs": {
    "category": "Foundational",
    "choco": "nodejs",
    "content": "Node.js",
    "description": "JavaScript runtime required by npm-distributed Channels DVR tools such as Prismcast.",
    "link": "https://nodejs.org/",
    "handle": "OpenJS Foundation",
    "winget": "OpenJS.NodeJS",
    "foss": true
  },
  "WPFInstallwsl2": {
    "category": "Foundational",
    "content": "WSL2",
    "description": "Windows Subsystem for Linux 2 - required to run Debian and any WSL-hosted Channels DVR add-ons. Enabling it for the first time may require a restart.",
    "link": "https://learn.microsoft.com/windows/wsl/",
    "handle": "Microsoft",
    "installType": "wslFeature",
    "foss": true
  },
  "WPFInstalldebian": {
    "category": "Foundational",
    "content": "Debian (WSL)",
    "description": "Debian Linux distro running under WSL2 - hosts the Olivetin (EZ-Start) docker setup. Opens automatically after installing so you can finish creating its Linux user account right away - that first-run step needs a real interactive console, so answer its username/password prompts in the window that appears.",
    "link": "https://www.debian.org/",
    "handle": "Debian Project",
    "winget": "Debian.Debian",
    "requires": [
      "wsl2"
    ],
    "postInstallCommand": "$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User'); Start-Process debian.exe",
    "foss": true
  },
  "WPFInstallchrome": {
    "category": "Foundational",
    "choco": "googlechrome",
    "content": "Chrome",
    "description": "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
    "link": "https://www.google.com/chrome/",
    "handle": "Google",
    "winget": "Google.Chrome.EXE",
    "foss": false
  },
  "WPFInstallfirefox": {
    "category": "Foundational",
    "choco": "firefox",
    "content": "Firefox",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "handle": "Mozilla",
    "winget": "Mozilla.Firefox",
    "foss": true
  },
  "WPFInstallvlc": {
    "category": "Foundational",
    "choco": "vlc",
    "content": "VLC",
    "description": "VLC media player is a free, open-source, cross-platform multimedia player that plays most local video/audio files and discs, by VideoLAN.",
    "link": "https://www.videolan.org/vlc/",
    "icon": "https://upload.wikimedia.org/wikipedia/commons/3/38/VLC_icon.png",
    "handle": "VideoLAN",
    "winget": "VideoLAN.VLC",
    "foss": true
  },
  "WPFInstallchannelsdvr": {
    "category": "Channels DVR",
    "content": "Channels DVR",
    "description": "Channels DVR Server - the core DVR backend service. Installer is interactive - no silent-install flag is documented. To uninstall: stop the DVR engine, then re-run the installer and choose Uninstall.",
    "link": "https://getchannels.com/dvr-server/",
    "icon": "https://getchannels.com/favicon.ico",
    "webui": "http://localhost:8089",
    "handle": "Fancy Bits LLC",
    "installType": "direct",
    "url": "https://channels-dvr.s3.amazonaws.com/SetupChannelsDVR.exe",
    "args": "",
    "uninstallViaInstaller": true,
    "foss": false
  },
  "WPFInstallolivetin": {
    "category": "Channels DVR",
    "content": "Olivetin EZ-Start",
    "subtitle": "(Includes Portainer)",
    "description": "Olivetin for Channels, run via docker inside the Debian WSL distro. Requires Docker Desktop with WSL integration enabled for Debian.",
    "link": "https://github.com/bnhf/OliveTin",
    "icon": "https://raw.githubusercontent.com/OliveTin/OliveTin/main/frontend/OliveTinLogo.png",
    "webui": "http://localhost:1338",
    "handle": "@bnhf",
    "installType": "wslCommand",
    "distro": "Debian",
    "requires": [
      "wsl2",
      "debian",
      "dockerdesktop"
    ],
    "requiresDockerInDistro": true,
    "prompts": [
      {
        "name": "PORTAINER_PASSWORD",
        "label": "Desired Portainer password (12 character minimum)",
        "secret": true,
        "minLength": 12
      }
    ],
    "command": "docker run -d --name olivetin-ezstart --pull always --add-host=host.docker.internal:host-gateway -p 1338:1337 -e EZ_START=-ezstart -e CHANNELS_DVR=host.docker.internal:8089 -e TZ=$(readlink /etc/localtime) -e HOST_DIR=$([[ \"$(uname)\" == \"Darwin\" ]] && echo \"$HOME\" || echo \"/data\") -e PORTAINER_PASSWORD='{{PORTAINER_PASSWORD}}' -v /config -v /var/run/docker.sock:/var/run/docker.sock bnhf/olivetin:latest",
    "uninstallCommand": "docker rm -f olivetin-ezstart",
    "foss": false
  },
  "WPFInstallstreamlinkmanager": {
    "category": "Channels DVR",
    "content": "Streaming Library Manager",
    "description": "Organizes movies, TV shows, and linear stations across streaming platforms for Channels DVR and Infuse, by babsonnexus. Installed natively rather than via the upstream slm.bat installer, which needs an interactive keypress to confirm and has no scripted uninstall - this downloads the same packaged release directly and registers it to start at logon.",
    "link": "https://github.com/babsonnexus/stream-link-manager-for-channels",
    "icon": "https://raw.githubusercontent.com/babsonnexus/stream-link-manager-for-channels/main/static/assets/img/slm_navicon.png",
    "webui": "http://localhost:5000",
    "handle": "@babsonnexus",
    "installType": "streamLinkManager",
    "foss": true
  },
  "WPFInstalldvrdesk": {
    "category": "Channels DVR Windows Clients",
    "content": "DVRDesk",
    "description": "Desktop client for Channels DVR by jay3702.",
    "link": "https://github.com/jay3702/DVRDesk",
    "icon": "https://raw.githubusercontent.com/jay3702/DVRDesk/main/src-tauri/icons/icon.png",
    "iconScale": 1.3,
    "handle": "@jay343",
    "installType": "github",
    "repo": "jay3702/DVRDesk",
    "assetPattern": "*_x64-setup.exe",
    "foss": true
  },
  "WPFInstallferalhtpc": {
    "category": "Channels DVR Windows Clients",
    "content": "Feral HTPC",
    "description": "Feral HTPC front-end for Channels DVR by nuken.",
    "link": "https://github.com/nuken/Feral-HTPC",
    "icon": "https://raw.githubusercontent.com/nuken/Feral-HTPC/main/Assets/appicon.ico",
    "handle": "@Bobby_Vaughn",
    "installType": "github",
    "repo": "nuken/Feral-HTPC",
    "assetPattern": "*Setup.exe",
    "foss": true
  },
  "WPFInstallnukenhtpc": {
    "category": "Channels DVR Windows Clients",
    "content": "Nucleus HTPC",
    "description": "HTPC front-end for Channels DVR by nuken.",
    "link": "https://github.com/nuken/HTPC",
    "icon": "https://raw.githubusercontent.com/nuken/HTPC/main/Assets/Nucleus.png",
    "handle": "@Bobby_Vaughn",
    "installType": "github",
    "repo": "nuken/HTPC",
    "assetPattern": "NucleusHTPC_Installer_*.exe",
    "foss": true
  },
  "WPFInstallrustdvr": {
    "category": "Channels DVR Windows Clients",
    "content": "Clicker",
    "description": "Native Win32 client for Channels DVR written in Rust with WinUI3 styling, by mackid1993 (formerly RustDVR). Not affiliated or endorsed by Fancy Bits LLC.",
    "link": "https://github.com/mackid1993/Clicker",
    "icon": "https://git-scm.com/images/logos/downloads/Git-Icon-1788C.png",
    "handle": "@mackid1993",
    "installType": "github",
    "repo": "mackid1993/Clicker",
    "assetPattern": "Clicker-Setup-*.exe",
    "foss": true
  },
  "WPFInstallplutoforchannels": {
    "category": "Channels DVR Sources (non-Docker)",
    "content": "Pluto for Channels",
    "description": "Pluto TV integration for Channels DVR by nuken.",
    "link": "https://github.com/nuken/Pluto-Windows_4C",
    "icon": "https://raw.githubusercontent.com/nuken/Pluto-Windows_4C/main/icon.ico",
    "webui": "http://localhost:7777",
    "handle": "@Bobby_Vaughn",
    "installType": "github",
    "repo": "nuken/Pluto-Windows_4C",
    "assetPattern": "PlutoForChannels*.exe",
    "foss": true
  },
  "WPFInstallandroidadbbridge": {
    "category": "Channels DVR Sources (non-Docker)",
    "content": "Android ADB Bridge",
    "description": "Android ADB bridge tool for Channels DVR by nuken.",
    "link": "https://github.com/nuken/Android-ADB-Bridge",
    "icon": "https://raw.githubusercontent.com/nuken/Android-ADB-Bridge/main/icon.ico",
    "webui": "http://localhost:8888/status",
    "handle": "@Bobby_Vaughn",
    "installType": "github",
    "repo": "nuken/Android-ADB-Bridge",
    "assetPattern": "AndroidBridge_Setup_*.exe",
    "foss": true
  },
  "WPFInstallprismcast": {
    "category": "Channels DVR Sources (non-Docker)",
    "content": "Prismcast",
    "description": "Chrome-based streaming server for Channels DVR and Plex, by hjdhjd. Requires Node.js 22+ and Google Chrome.",
    "link": "https://github.com/hjdhjd/prismcast",
    "icon": "https://raw.githubusercontent.com/hjdhjd/prismcast/main/prismcast.png",
    "iconScale": 1.3,
    "webui": "http://localhost:5589",
    "handle": "@hjd",
    "installType": "npm",
    "npmPackage": "prismcast",
    "postInstallCommand": "prismcast service install",
    "requires": [
      "nodejs",
      "chrome"
    ],
    "foss": true
  }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
  "WPFInstall": {
    "Content": "Install/Upgrade Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "1",
    "Description": "Install or upgrade the selected applications"
  },
  "WPFUninstall": {
    "Content": "Uninstall Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "2",
    "Description": "Uninstall the selected applications"
  },
  "WPFInstallUpgrade": {
    "Content": "Upgrade all Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "3",
    "Description": "Upgrade all applications to the latest version"
  },
  "WingetRadioButton": {
    "Content": "WinGet",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "Use WinGet for package management"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "Use Chocolatey for package management"
  },
  "WPFCollapseAllCategories": {
    "Content": "Collapse All Categories",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "1",
    "Description": "Collapse all application categories"
  },
  "WPFExpandAllCategories": {
    "Content": "Expand All Categories",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "2",
    "Description": "Expand all application categories"
  },
  "WPFClearInstallSelection": {
    "Content": "Clear Selection",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "3",
    "Description": "Clear the selection of applications"
  },
  "WPFGetInstalled": {
    "Content": "Show Installed Apps",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "4",
    "Description": "Show installed applications"
  },
  "WPFselectedAppsButton": {
    "Content": "Selected Apps: 0",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "5",
    "Description": "Show the selected applications"
  },
  "WPFInstallFOSSInfo": {
    "Content": "Free and Open Source Software",
    "Category": "__Selection",
    "Type": "Note",
    "Order": "0",
    "Description": "Information about the #FOSS label on application entries"
  }
}
'@ | ConvertFrom-Json
$sync.configs.appx = @'
{
  "WPFAppxMicrosoft_WindowsFeedbackHub": {
    "Category": "Microsoft Apps",
    "Content": "Feedback Hub",
    "Description": "Allows users to submit bug reports, feature suggestions, and diagnostic data directly to Microsoft.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsFeedbackHub",
    "StoreId": "9NBLGGH4R32N"
  },
  "WPFAppxMicrosoft_GetHelp": {
    "Category": "Microsoft Apps",
    "Content": "Get Help",
    "Description": "Provides access to automated troubleshooting guides, support documentation, and direct Microsoft customer assistance.",
    "Panel": "0",
    "PackageId": "Microsoft.GetHelp",
    "StoreId": "9PKDZBMV1H3T"
  },
  "WPFAppxMicrosoft_OutlookForWindows": {
    "Category": "Microsoft Apps",
    "Content": "Outlook for Windows",
    "Description": "Provides modern email management, calendar scheduling, and contact organization features.",
    "Panel": "0",
    "PackageId": "Microsoft.OutlookForWindows",
    "StoreId": "9NRX63209R7B"
  },
  "WPFAppxMSTeams": {
    "Category": "Microsoft Apps",
    "Content": "Microsoft Teams",
    "Description": "Facilitates instant messaging, video conferencing, file sharing, and workspace collaboration.",
    "Panel": "0",
    "PackageId": "MSTeams",
    "StoreId": "XP8BT8DW290MPQ"
  },
  "WPFAppxClipchamp_Clipchamp": {
    "Category": "Utilities & Productivity",
    "Content": "Clipchamp",
    "Description": "Provides a user-friendly video editor with built-in templates, effects, and timeline editing tools.",
    "Panel": "0",
    "PackageId": "Clipchamp.Clipchamp",
    "StoreId": "9P1J8S7CCWWT"
  },
  "WPFAppxMicrosoft_MicrosoftOfficeHub": {
    "Category": "Microsoft Apps",
    "Content": "Microsoft 365",
    "Description": "Serves as a centralized launcher and dashboard for accessing cloud-based Microsoft 365 apps and recent documents.",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftOfficeHub",
    "StoreId": "9WZDNCRD29V9"
  },
  "WPFAppxMicrosoft_ZuneMusic": {
    "Category": "Utilities & Productivity",
    "Content": "Media Player",
    "Description": "Plays local audio and video files with modern playlist management and casting capabilities.",
    "Panel": "0",
    "PackageId": "Microsoft.ZuneMusic",
    "StoreId": "9WZDNCRFJ3PT"
  },
  "WPFAppxMicrosoft_BingSearch": {
    "Category": "Bing & Web Services",
    "Content": "Bing Search",
    "Description": "Integrates Microsoft Bing search capabilities and web services directly into the operating system.",
    "Panel": "1",
    "PackageId": "Microsoft.BingSearch",
    "StoreId": "9NZBF4GT040C"
  },
  "WPFAppxMicrosoftCorporationII_QuickAssist": {
    "Category": "Utilities & Productivity",
    "Content": "Quick Assist",
    "Description": "Enables secure remote technical support and screen sharing over an internet connection.",
    "Panel": "0",
    "PackageId": "MicrosoftCorporationII.QuickAssist",
    "StoreId": "9P7BP5VNWKX5"
  },
  "WPFAppxMicrosoft_WindowsDevHome": {
    "Category": "Developer Tools",
    "Content": "Dev Home",
    "Description": "Provides a specialized dashboard for software developer environment setups, repository syncing, and hardware widgets.",
    "Panel": "1",
    "PackageId": "Microsoft.Windows.DevHome",
    "StoreId": "9N8MHTPHNGVV"
  },
  "WPFAppxMicrosoft_WindowsCrossDevice": {
    "Category": "Microsoft Ecosystem",
    "Content": "Mobile Devices",
    "Description": "Manages system-level background connectivity with paired mobile devices. Removing this may disable cross-device features such as phone screen mirroring, file transfer, and mobile hotspot handoff integrated into Windows Settings.",
    "Panel": "0",
    "PackageId": "MicrosoftWindows.CrossDevice",
    "StoreId": "9NTXGKQ8P7N0"
  },
  "WPFAppxMicrosoft_Todos": {
    "Category": "Utilities & Productivity",
    "Content": "To Do",
    "Description": "Creates, tracks, and synchronizes personal tasks, smart lists, and daily reminders.",
    "Panel": "0",
    "PackageId": "Microsoft.Todos",
    "StoreId": "9NBLGGH5R558"
  },
  "WPFAppxMicrosoft_PowerAutomateDesktop": {
    "Category": "Developer Tools",
    "Content": "Power Automate",
    "Description": "Automates repetitive workflows and desktop tasks using low-code visual scripting.",
    "Panel": "1",
    "PackageId": "Microsoft.PowerAutomateDesktop",
    "StoreId": "9NFTCH6J7FHV"
  },
  "WPFAppxMicrosoft_YourPhone": {
    "Category": "Microsoft Ecosystem",
    "Content": "Phone Link",
    "Description": "Synchronizes text messages, phone notifications, photos, and calls from a mobile device to the desktop.",
    "Panel": "0",
    "PackageId": "Microsoft.YourPhone",
    "StoreId": "9NMPJ99VJBWV"
  },
  "WPFAppxMicrosoft_MicrosoftStickyNotes": {
    "Category": "Utilities & Productivity",
    "Content": "Sticky Notes",
    "Description": "Creates quick, floating text notes on the desktop that automatically sync across devices.",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftStickyNotes",
    "StoreId": "9NBLGGH4QGHW"
  },
  "WPFAppxMicrosoft_WindowsSoundRecorder": {
    "Category": "Utilities & Productivity",
    "Content": "Sound Recorder",
    "Description": "Records and trims live audio inputs with simple microphone adjustment controls.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsSoundRecorder",
    "StoreId": "9WZDNCRFHWKN"
  },
  "WPFAppxMicrosoft_WindowsAlarms": {
    "Category": "Utilities & Productivity",
    "Content": "Clock",
    "Description": "Features world clocks, alarms, countdown timers, stopwatches, and dedicated focus session tracking.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsAlarms",
    "StoreId": "9WZDNCRFJ3PR"
  },
  "WPFAppxMicrosoft_Paint": {
    "Category": "Utilities & Productivity",
    "Content": "Paint",
    "Description": "Provides built-in digital sketching, basic image editing, and pixel-level graphic manipulation tools.",
    "Panel": "0",
    "PackageId": "Microsoft.Paint",
    "StoreId": "9PCFS5B6T72H"
  },
  "WPFAppxMicrosoft_WindowsNotepad": {
    "Category": "Utilities & Productivity",
    "Content": "Notepad",
    "Description": "Provides a lightweight text editor with multi-tab support for plain text files and code snippets.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsNotepad",
    "StoreId": "9MSMLRH6LZF3"
  },
  "WPFAppxMicrosoft_ScreenSketch": {
    "Category": "Utilities & Productivity",
    "Content": "Snipping Tool",
    "Description": "Captures screenshots or screen recordings with built-in markup, image cropping, and optical character recognition (OCR).",
    "Panel": "0",
    "PackageId": "Microsoft.ScreenSketch",
    "StoreId": "9MZ95KL8MR0L"
  },
  "WPFAppxMicrosoft_Copilot": {
    "Category": "Bing & Web Services",
    "Content": "Copilot",
    "Description": "Launches the Microsoft AI companion for contextual answers, creative writing assistance, and intelligent web search.",
    "Panel": "1",
    "PackageId": "Microsoft.Copilot",
    "StoreId": "9NHT9RB2F4HD"
  },
  "WPFAppxMicrosoft_WindowsCalculator": {
    "Category": "Utilities & Productivity",
    "Content": "Calculator",
    "Description": "Performs standard arithmetic, scientific operations, programming calculations, and unit conversions.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCalculator",
    "StoreId": "9WZDNCRFHVN5"
  },
  "WPFAppxMicrosoft_WindowsCamera": {
    "Category": "Utilities & Productivity",
    "Content": "Camera",
    "Description": "Captures photographs and records video files via connected webcams or imaging hardware.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCamera",
    "StoreId": "9WZDNCRFJBBG"
  },
  "WPFAppxMicrosoft_WindowsPhotos": {
    "Category": "Utilities & Productivity",
    "Content": "Photos",
    "Description": "Organizes, views, and crops local images with basic color adjustment and album creation tools.",
    "Panel": "0",
    "PackageId": "Microsoft.Windows.Photos",
    "StoreId": "9WZDNCRFJBH4"
  },
  "WPFAppxMicrosoft_BingNews": {
    "Category": "Bing & Web Services",
    "Content": "News",
    "Description": "Aggregates breaking news headlines, personalized article feeds, and world current events.",
    "Panel": "1",
    "PackageId": "Microsoft.BingNews",
    "StoreId": "9WZDNCRFHVFW"
  },
  "WPFAppxMicrosoft_BingWeather": {
    "Category": "Bing & Web Services",
    "Content": "Weather",
    "Description": "Displays local real-time weather tracking, radar maps, and historical meteorological forecasts.",
    "Panel": "1",
    "PackageId": "Microsoft.BingWeather",
    "StoreId": "9WZDNCRFJ3Q2"
  },
  "WPFAppxMicrosoft_GamingApp": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox App",
    "Description": "Serves as the primary gaming library manager, social community interface, and PC Game Pass dashboard.",
    "Panel": "1",
    "PackageId": "Microsoft.GamingApp",
    "StoreId": "9MV0B5HZVK9Z"
  },
  "WPFAppxMicrosoft_XboxGamingOverlay": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Game Bar",
    "Description": "Provides customizable in-game status widgets, audio balancing sliders, system monitoring tools, and gameplay recording.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxGamingOverlay",
    "StoreId": "9NZKPSTSNW4P"
  },
  "WPFAppxMicrosoft_XboxIdentityProvider": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Identity Provider",
    "Description": "Manages Xbox network user authentication and background account validation for connected titles. Warning: removing this may break Microsoft account sign-in for non-Xbox games and apps that rely on this authentication pipeline.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxIdentityProvider",
    "StoreId": "9WZDNCRD1HKW"
  },
  "WPFAppxMicrosoft_XboxSpeechToTextOverlay": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Speech To Text Overlay",
    "Description": "Provides system-level live accessibility captions and voice-to-text translation for gaming chat networks.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxSpeechToTextOverlay"
  },
  "WPFAppxMicrosoft_Xbox_TCUI": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox TCUI",
    "Description": "Provides core account connection UI modules for single sign-on flows within game titles. Warning: removing this may break Microsoft account authentication in games and apps that do not otherwise require the Xbox app.",
    "Panel": "1",
    "PackageId": "Microsoft.Xbox.TCUI"
  },
  "WPFAppxMicrosoft_StartExperiencesApp": {
    "Category": "Bing & Web Services",
    "Content": "Start Experiences App",
    "Description": "Powers the Windows Widgets board, delivering a personalized feed of news, weather, sports, and finance content.",
    "Panel": "1",
    "PackageId": "Microsoft.StartExperiencesApp",
    "StoreId": "9PC1H9VN18CM"
  },
  "WPFAppxMicrosoft_MicrosoftSolitaireCollection": {
    "Category": "Xbox & Gaming",
    "Content": "Solitaire Collection",
    "Description": "Bundles built-in card game modes including Klondike, Spider, FreeCell, Pyramid, and TriPeaks alongside daily challenges.",
    "Panel": "1",
    "PackageId": "Microsoft.MicrosoftSolitaireCollection"
  }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
  "Google": {
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844",
    "DohTemplate": "https://dns.google/dns-query"
  },
  "Cloudflare": {
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001",
    "DohTemplate": "https://cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002",
    "DohTemplate": "https://security.cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003",
    "DohTemplate": "https://family.cloudflare-dns.com/dns-query"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53",
    "DohTemplate": "https://doh.opendns.com/dns-query"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9",
    "DohTemplate": "https://dns.quad9.net/dns-query"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff",
    "DohTemplate": "https://dns.adguard-dns.com/dns-query"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff",
    "DohTemplate": "https://family.adguard-dns.com/dns-query"
  }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": ".NET Framework (Versions 2, 3, 4) - Enable",
    "Description": ".NET and .NET Framework is a developer platform made up of tools, programming languages, and libraries for building many different types of applications.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/code-reference/features/features/dotnet"
  },
  "WPFFixesNTPPool": {
    "Content": "NTP Server - Enable",
    "Description": "Replaces the default Windows NTP server (time.windows.com) with pool.ntp.org for improved time synchronization accuracy and reliability.",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNTPPool",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/ntppool"
  },
  "WPFFeatureshyperv": {
    "Content": "Hyper-V - Enable",
    "Description": "Hyper-V is a hardware virtualization product developed by Microsoft that allows users to create and manage virtual machines.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "Microsoft-Hyper-V-All"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/hyperv"
  },
  "WPFFeatureslegacymedia": {
    "Content": "Legacy Media Components (WMP, DirectPlay) - Enable",
    "Description": "Enables legacy programs from previous versions of Windows.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/code-reference/features/features/legacymedia"
  },
  "WPFFeaturewsl": {
    "Content": "Windows Subsystem for Linux (WSL) - Enable",
    "Description": "Windows Subsystem for Linux is an optional feature of Windows that allows Linux programs to run natively on Windows without the need for a separate virtual machine or dual booting.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/code-reference/features/features/wsl"
  },
  "WPFFeaturenfs": {
    "Content": "Network File System (NFS) - Enable",
    "Description": "Network File System (NFS) is a mechanism for storing files on a network.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/nfs"
  },
  "WPFFeatureRegBackup": {
    "Content": "Registry Backup (Daily Task 12:30am) - Enable",
    "Description": "Enables daily registry backup, previously disabled by Microsoft in Windows 10 1803.",
    "category": "Features",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/regbackup"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "Legacy F8 Boot Recovery - Enable",
    "Description": "Enables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy legacy"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/enablelegacyrecovery"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "Legacy F8 Boot Recovery - Disable",
    "Description": "Disables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy standard"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/disablelegacyrecovery"
  },
  "WPFFeaturesSandbox": {
    "Content": "Windows Sandbox - Enable",
    "Description": "Windows Sandbox is a lightweight virtual machine that provides a temporary desktop environment to safely run applications and programs in isolation.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "Containers-DisposableClientVM"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/sandbox"
  },
  "WPFFeatureInstall": {
    "Content": "Install Features",
    "category": "Features",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFeatureInstall",
    "link": "https://winutil.christitus.com/code-reference/features/features/install"
  },
  "WPFPanelAutologin": {
    "Content": "AutoLogon - Run",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFPanelAutologin",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/autologin"
  },
  "WPFFixesUpdate": {
    "Content": "Windows Update - Reset",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesUpdate",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/update"
  },
  "WPFFixesNetwork": {
    "Content": "Network - Reset",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNetwork",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/network"
  },
  "WPFPanelDISM": {
    "Content": "System Corruption Scan - Run",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSystemRepair",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/dism"
  },
  "WPFFixesWinget": {
    "Content": "WinGet - Reinstall",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesWinget",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/winget"
  },
  "WPFPanelComputer": {
    "Content": "Computer Management",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "compmgmt.msc"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/computer"
  },
  "WPFPanelControl": {
    "Content": "Control Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "control"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/control"
  },
  "WPFPanelMouse": {
    "Content": "Mouse Properties",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "main.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/mouse"
  },
  "WPFPanelNetwork": {
    "Content": "Network Connections",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "ncpa.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/network"
  },
  "WPFPanelPower": {
    "Content": "Power Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "powercfg.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/power"
  },
  "WPFPanelPrinter": {
    "Content": "Printer Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "Start-Process 'shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}'"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/printer"
  },
  "WPFPanelPrograms": {
    "Content": "Programs and Features",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "appwiz.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/programs"
  },
  "WPFPanelRegion": {
    "Content": "Region",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "intl.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/region"
  },
  "WPFPanelSecurity": {
    "Content": "Security and Maintenance",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "wscui.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/security"
  },
  "WPFPanelSound": {
    "Content": "Sound Settings",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "mmsys.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/sound"
  },
  "WPFPanelSystem": {
    "Content": "System Properties",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "sysdm.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/system"
  },
  "WPFPanelTimedate": {
    "Content": "Time and Date",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "timedate.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/timedate"
  },
  "WPFPanelFirewall": {
    "Content": "Windows Defender Firewall",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "firewall.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/firewall"
  },
  "WPFPanelRestore": {
    "Content": "Windows Restore",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "rstrui.exe"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/restore"
  },
  "WPFWinUtilInstallPSProfile": {
    "Content": "CTT PowerShell Profile - Install",
    "category": "Powershell Profile Powershell 7+ Only",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilInstallPSProfile",
    "link": "https://winutil.christitus.com/code-reference/features/powershell-profile-powershell-7--only/installpsprofile"
  },
  "WPFWinUtilUninstallPSProfile": {
    "Content": "CTT PowerShell Profile - Remove",
    "category": "Powershell Profile Powershell 7+ Only",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilUninstallPSProfile",
    "link": "https://winutil.christitus.com/code-reference/features/powershell-profile-powershell-7--only/uninstallpsprofile"
  },
  "WPFWinUtilSSHServer": {
    "Content": "OpenSSH Server - Enable",
    "category": "Remote Access",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSSHServer",
    "link": "https://winutil.christitus.com/code-reference/features/remote-access/sshserver"
  }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksWPBT",
    "WPFTweaksServices",
    "WPFTweaksTelemetry"
  ],
  "Advanced": [
    "WPFTweaksRestorePoint",
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksDisableStoreSearch",
    "WPFTweaksRevertStartMenu",
    "WPFTweaksWidget",
    "WPFTweaksRemoveOneDrive",
    "WPFTweaksWindowsAI",
    "WPFTweaksRightClickMenu"
  ],
  "AppxDefault": [
    "WPFAppxMicrosoft_WindowsFeedbackHub",
    "WPFAppxMicrosoft_GetHelp",
    "WPFAppxMicrosoft_MicrosoftOfficeHub",
    "WPFAppxMicrosoft_WindowsCalculator",
    "WPFAppxClipchamp_Clipchamp",
    "WPFAppxMicrosoft_WindowsAlarms",
    "WPFAppxMicrosoftCorporationII_QuickAssist",
    "WPFAppxMicrosoft_WindowsSoundRecorder",
    "WPFAppxMicrosoft_MicrosoftStickyNotes",
    "WPFAppxMicrosoft_Todos",
    "WPFAppxMicrosoft_MicrosoftSolitaireCollection",
    "WPFAppxMicrosoft_PowerAutomateDesktop",
    "WPFAppxMicrosoft_WindowsDevHome",
    "WPFAppxMicrosoft_BingWeather",
    "WPFAppxMicrosoft_StartExperiencesApp",
    "WPFAppxMicrosoft_BingNews",
    "WPFAppxMicrosoft_Copilot",
    "WPFAppxMicrosoft_BingSearch"
  ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
  "shared": {
    "AppEntryWidth": "220",
    "AppEntryFontSize": "13.2",
    "AppEntrySubtitleFontSize": "10.5",
    "AppEntryNameMaxWidth": "150",
    "AppEntryNameMinHeight": "34",
    "AppEntryIconSize": "28",
    "AppEntryMargin": "3",
    "AppEntryBorderThickness": "1",
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Arial",
    "HeaderFontSize": "16",
    "HeaderFontFamily": "Consolas, Monaco",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "110",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "ToolTipWidth": "300",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "12",
    "GroupBorderBackgroundColor": "#232629",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Arial",
    "ButtonWidth": "200",
    "ButtonHeight": "25",
    "ConfigTabButtonFontSize": "14",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "CheckboxMouseOverColor": "#999999",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "2"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F7F7F7",
    "AppInstallHighlightedColor": "#CFCFCF",
    "AppInstallSelectedColor": "#C2C2C2",
    "ComboBoxForegroundColor": "#232629",
    "ComboBoxBackgroundColor": "#F7F7F7",
    "LabelboxForegroundColor": "#232629",
    "MainForegroundColor": "#232629",
    "MainBackgroundColor": "#F7F7F7",
    "LabelBackgroundColor": "#F7F7F7",
    "LinkForegroundColor": "#484848",
    "LinkHoverForegroundColor": "#232629",
    "ScrollBarBackgroundColor": "#4A4D52",
    "ScrollBarHoverColor": "#5A5D62",
    "ScrollBarDraggingColor": "#6A6D72",
    "ProgressBarForegroundColor": "#2E77FF",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#F7F7F7",
    "ButtonTweaksBackgroundColor": "#F7F7F7",
    "ButtonConfigBackgroundColor": "#F7F7F7",
    "ButtonUpdatesBackgroundColor": "#F7F7F7",
    "ButtonWin11ISOBackgroundColor": "#F7F7F7",
    "ButtonAppxBackgroundColor": "#F7F7F7",
    "ButtonInstallForegroundColor": "#232629",
    "ButtonTweaksForegroundColor": "#232629",
    "ButtonConfigForegroundColor": "#232629",
    "ButtonUpdatesForegroundColor": "#232629",
    "ButtonWin11ISOForegroundColor": "#232629",
    "ButtonAppxForegroundColor": "#232629",
    "ButtonBackgroundColor": "#F5F5F5",
    "ButtonBackgroundPressedColor": "#1A1A1A",
    "ButtonBackgroundMouseoverColor": "#C2C2C2",
    "ButtonBackgroundSelectedColor": "#F0F0F0",
    "ButtonForegroundColor": "#232629",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#F7F7F7",
    "BorderColor": "#232629",
    "BorderOpacity": "0.2"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#232629",
    "AppInstallHighlightedColor": "#3C3C3C",
    "AppInstallSelectedColor": "#4C4C4C",
    "ComboBoxForegroundColor": "#F7F7F7",
    "ComboBoxBackgroundColor": "#1E3747",
    "LabelboxForegroundColor": "#5BDCFF",
    "MainForegroundColor": "#F7F7F7",
    "MainBackgroundColor": "#232629",
    "LabelBackgroundColor": "#232629",
    "LinkForegroundColor": "#ADD8E6",
    "LinkHoverForegroundColor": "#F7F7F7",
    "ScrollBarBackgroundColor": "#2E3135",
    "ScrollBarHoverColor": "#3B4252",
    "ScrollBarDraggingColor": "#5E81AC",
    "ProgressBarForegroundColor": "#6EFF72",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#222222",
    "ButtonTweaksBackgroundColor": "#333333",
    "ButtonConfigBackgroundColor": "#444444",
    "ButtonUpdatesBackgroundColor": "#555555",
    "ButtonWin11ISOBackgroundColor": "#666666",
    "ButtonAppxBackgroundColor": "#777777",
    "ButtonInstallForegroundColor": "#F7F7F7",
    "ButtonTweaksForegroundColor": "#F7F7F7",
    "ButtonConfigForegroundColor": "#F7F7F7",
    "ButtonUpdatesForegroundColor": "#F7F7F7",
    "ButtonWin11ISOForegroundColor": "#F7F7F7",
    "ButtonAppxForegroundColor": "#F7F7F7",
    "ButtonBackgroundColor": "#1E3747",
    "ButtonBackgroundPressedColor": "#F7F7F7",
    "ButtonBackgroundMouseoverColor": "#3B4252",
    "ButtonBackgroundSelectedColor": "#5E81AC",
    "ButtonForegroundColor": "#F7F7F7",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#2F373D",
    "BorderColor": "#2F373D",
    "BorderOpacity": "0.2"
  }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
  "WPFTweaksActivity": {
    "Content": "Activity History - Disable",
    "Description": "Erases recent docs, clipboard, and run history.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/activity"
  },
  "WPFTweaksHiber": {
    "Content": "Hibernation - Disable",
    "Description": "Hibernation is really meant for laptops as it saves what's in memory before turning the PC off. It really should never be used.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/hiber"
  },
  "WPFTweaksWidget": {
    "Content": "Widgets - Remove",
    "Description": "Removes the annoying widgets in the bottom left of the Taskbar.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Get-Process *Widget* | Stop-Process\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/widget"
  },
  "WPFTweaksRevertStartMenu": {
    "Content": "Start Menu Previous Layout - Enable",
    "Description": "Bring back the old Start Menu layout from before the gradual rollout of the new one in 25H2. On newer versions of Windows !!THIS TWEAK WILL NOT WORK!!",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\8\\3036241548",
        "Name": "EnabledState",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/revertstartmenu"
  },
  "WPFTweaksDisableStoreSearch": {
    "Content": "Microsoft Store Recommended Search Results - Disable",
    "Description": "Will not display recommended Microsoft Store apps when searching for apps in the Start menu.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
    ],
    "UndoScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablestoresearch"
  },
  "WPFTweaksLocation": {
    "Content": "Location Tracking - Disable",
    "Description": "Disables Location Tracking.",
    "category": "Essential Tweaks",
    "panel": "1",
    "service": [
      {
        "Name": "lfsvc",
        "StartupType": "Disable",
        "OriginalType": "Manual"
      }
    ],
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Value": "Deny",
        "Type": "String",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/location"
  },
  "WPFTweaksServices": {
    "Content": "Services - Set to Manual",
    "Description": "Sets some services to Manual startup and adjusts the SvcHostSplitThresholdInKB registry value to better match system memory, which can significantly reduce the number of svchost.exe processes.",
    "category": "Essential Tweaks",
    "panel": "1",
    "service": [
      {
        "Name": "CscService",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      }
    ],
    "InvokeScript": [
      "\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/services"
  },
  "WPFTweaksBraveDebloat": {
    "Content": "Brave Browser - Debloat",
    "Description": "Disables various annoyances like Brave Rewards, Leo AI, Crypto Wallet and VPN.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveRewardsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveWalletDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveVPNDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveAIChatEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveStatsPingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveNewsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveTalkDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "TorDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveP3AEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "UrlKeyedAnonymizedDataCollectionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "SafeBrowsingExtendedReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "MetricsReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/bravedebloat"
  },
  "WPFTweaksDisableWarningForUnsignedRdp": {
    "Content": "RDP Unsigned File Warnings - Disable",
    "Description": "Disables warnings shown when launching unsigned RDP files introduced with the latest Windows 10 and 11 updates.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
        "Name": "RedirectionWarningDialogVersion",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
        "Name": "RdpLaunchConsentAccepted",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablewarningforunsignedrdp"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Microsoft Edge - Debloat",
    "Description": "Disables various telemetry options, popups, and other annoyances in Edge.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
        "Name": "1",
        "Value": "ofefcgjbeghpigppfmkologfjadafddi",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DefaultBrowserSettingsCampaignEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/edgedebloat"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "ConsumerFeatures - Disable",
    "Description": "Stops promoted app installs and reduces app suggestions from Microsoft Store content.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/consumerfeatures"
  },
  "WPFTweaksTelemetry": {
    "Content": "Telemetry - Disable",
    "Description": "Disables Microsoft Telemetry.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
        "Name": "TailoredExperiencesWithDiagnosticDataEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
        "Name": "HasAccepted",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Input\\TIPC",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitInkCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitTextCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
        "Name": "HarvestContacts",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
        "Name": "AcceptedPrivacyPolicy",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Start_TrackProgs",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Disabled\r\n\r\n      # Disable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Disabled\r\n\r\n      # Disable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')\r\n\r\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Automatic\r\n\r\n      # Enable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Automatic\r\n\r\n      # Enable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/telemetry"
  },
  "WPFTweaksDeliveryOptimization": {
    "Content": "Delivery Optimization - Disable",
    "Description": "Stops Windows from using your bandwidth to upload updates to other PCs on the internet or local network.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
        "Name": "DODownloadMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deliveryoptimization"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "Microsoft Edge - Remove",
    "Description": "Uninstalls Microsoft Edge by creating dummy MicrosoftEdge.exe file in the legacy Edge folder. This tricks Windows into unlocking the official Edge uninstaller allowing for a system-level removal.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $Path = Resolve-Path -Path \"$Env:ProgramFiles (x86)\\Microsoft\\Edge\\Application\\*\\Installer\\setup.exe\" | Select-Object -Last 1\r\n\r\n      if (Test-Path $Path) {\r\n          New-Item -Path \"$Env:SystemRoot\\SystemApps\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\MicrosoftEdge.exe\" -Force\r\n          Start-Process -FilePath $Path -ArgumentList \"--uninstall --system-level --force-uninstall --delete-profile\" -Wait\r\n          Write-Host \"Microsoft Edge was removed\"\r\n      } else {\r\n          Write-Host \"Microsoft Edge is not installed\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing Microsoft Edge...\"\r\n      winget install Microsoft.Edge --source winget\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeedge"
  },
  "WPFTweaksDisableBitLocker": {
    "Content": "BitLocker - Disable",
    "Description": "Disables BitLocker.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "Disable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "UndoScript": [
      "Enable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablebitlocker"
  },
  "WPFTweaksUTC": {
    "Content": "Date & Time - Set Time to UTC",
    "Description": "Essential for computers that are dual booting. Fixes the time sync with Linux systems.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Value": "1",
        "Type": "QWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/utc"
  },
  "WPFTweaksRemoveOneDrive": {
    "Content": "Microsoft OneDrive - Remove",
    "Description": "Denies permission to remove OneDrive user files, then uses its own uninstaller to remove it and restores the original permission afterward.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Deny permission to remove OneDrive folder\r\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\r\n\r\n      Write-Host \"Uninstalling OneDrive...\"\r\n      Start-Process -FilePath (Join-Path $Env:SystemRoot \"System32\\OneDriveSetup.exe\") -ArgumentList '/uninstall' -Wait\r\n\r\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n      Write-Host \"Removing leftover OneDrive Files...\"\r\n\r\n      Stop-Process -Name FileCoAuth,Explorer\r\n\r\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\r\n      Remove-Item \"$Env:ProgramData\\Microsoft OneDrive\" -Recurse -Force\r\n\r\n      # Grant back permission to access OneDrive folder\r\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\r\n\r\n      if (-not (Get-ChildItem -Path $Env:OneDrive)) {\r\n          Remove-Item -Path $Env:OneDrive -Recurse\r\n          [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')\r\n      }\r\n\r\n      # Disable OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enabled OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Automatic\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeonedrive"
  },
  "WPFTweaksRemoveHomeAndGallery": {
    "Content": "File Explorer Home and Gallery - Disable",
    "Description": "Removes the Home and Gallery from Explorer and sets This PC as default.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "LaunchTo",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removehomeandgallery"
  },
  "WPFTweaksDisplay": {
    "Content": "Visual Effects - Set to Best Performance",
    "Description": "Sets the system preferences to performance. You can do this manually with sysdm.cpl as well.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "DragFullWindows",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String",
        "OriginalValue": "400"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewAlphaSelect",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewShadow",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAnimations",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\DWM",
        "Name": "EnableAeroPeek",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarMn",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/display"
  },
  "WPFTweaksReservedStorage": {
    "Content": "Disable Reserved Storage",
    "Description": "Disables Windows Reserved Storage (7-10 GB held for updates/temp files). Recommended only on small drives. Re-enable before major Windows feature updates to avoid installation failures.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "DISM /Online /Set-ReservedStorageState /State:Disabled"
    ],
    "UndoScript": [
      "DISM /Online /Set-ReservedStorageState /State:Enabled"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/reservedstorage"
  },
  "WPFTweaksRestorePoint": {
    "Content": "Restore Point - Create",
    "Description": "Creates a restore point at runtime in case a revert is needed from WinUtil modifications.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Checked": "False",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
        "Name": "SystemRestorePointCreationFrequency",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1440"
      }
    ],
    "InvokeScript": [
      "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/restorepoint"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "End Task With Right Click - Enable",
    "Description": "Enables option to end task when right clicking a program in the taskbar.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
        "Name": "TaskbarEndTask",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/endtaskontaskbar"
  },
  "WPFTweaksStorage": {
    "Content": "Storage Sense - Disable",
    "Description": "Storage Sense deletes temp files automatically.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
        "Name": "01",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/storage"
  },
  "WPFTweaksWindowsAI": {
    "Content": "Windows AI - Disable And Remove",
    "Description": "Removes and disables all AI features/packages",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "hide:aicomponents",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
        "Name": "DisableAIFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n\r\n      Get-AppxPackage -AllUsers \"*Copilot*\" | Remove-AppxPackage -AllUsers\r\n      winget uninstall -e --name \"Copilot\" --silent --force --accept-source-agreements 2>$null\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n\r\n      if ($Appx) {\r\n          Remove-AppxPackage $Appx\r\n      }\r\n\r\n      Set-Service -Name WSAIFabricSvc -StartupType Disabled\r\n      Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart\r\n\r\n      Write-Host \"Windows AI Disabled\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/windowsai"
  },
  "WPFTweaksWPBT": {
    "Content": "Windows Platform Binary Table (WPBT) - Disable",
    "Description": "If enabled, WPBT allows your computer vendor to execute programs at boot time, such as anti-theft software, software drivers, as well as force install software without user consent. Poses potential security risk.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/wpbt"
  },
  "WPFTweaksPreventDeviceMetadataFromNetwork": {
    "Content": "Prevent Device Companion Apps",
    "Description": "Prevents additional software from being installed when plugging in devices (e.g. Ads when plugging in a monitor). Poses potential security risk.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Device Metadata",
        "Name": "PreventDeviceMetadataFromNetwork",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/preventdevicemetadatafromnetwork"
  },
  "WPFTweaksRazerBlock": {
    "Content": "Razer Software Auto-Install - Disable",
    "Description": "Blocks ALL Razer Software installations. The hardware works fine without any software.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "\r\n      $RazerPath = \"$Env:SystemRoot\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"Everyone:(W)\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      icacls \"$Env:SystemRoot\\Installer\\Razer\" /remove:d Everyone\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/razerblock"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "System Tray Notifications & Calendar - Disable",
    "Description": "Disables all Notifications INCLUDING Calendar.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablenotifications"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "Adobe URL Block List - Enable",
    "Description": "Reduces user interruptions by selectively blocking connections to Adobe's activation and telemetry servers. Credit: Ruddernation-Designs",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $hostsUrl = Invoke-RestMethod -Uri https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\r\n      Add-Content -Path \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" -Value $hostsUrl\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Added Adobe url block list from host file'\r\n      "
    ],
    "UndoScript": [
      "\r\n      Set-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" (\r\n          (Get-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\") -join \"`n\" -replace '(?s)#New Ver.*', ''\r\n      )\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Removed Adobe url block list from host file'\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/blockadobenet"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "Right-Click Menu Previous Layout - Enable",
    "Description": "Restores the classic context menu when right-clicking in File Explorer, replacing the simplified Windows 11 version.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name InprocServer32 -Value \"\" -Force\r\n      Stop-Process -Name explorer\r\n      "
    ],
    "UndoScript": [
      "Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/rightclickmenu"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "Disk Cleanup - Run",
    "Description": "Runs Disk Cleanup on Drive C: and removes old Windows Updates.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/diskcleanup"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "Temporary Files - Remove",
    "Description": "Erases TEMP Folders.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deletetempfiles"
  },
  "WPFTweaksIPv46": {
    "Content": "IPv6 - Set IPv4 as Preferred",
    "Description": "Setting the IPv4 preference can have latency and security benefits on private networks where IPv6 is not configured.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/ipv46"
  },
  "WPFTweaksTeredo": {
    "Content": "Teredo - Disable",
    "Description": "Teredo network tunneling is an IPv6 feature that can cause additional latency, but may cause problems with some games.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/teredo"
  },
  "WPFTweaksDisableIPv6": {
    "Content": "IPv6 - Disable",
    "Description": "Disables IPv6.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disableipv6"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "Background Apps - Disable",
    "Description": "Disables all Microsoft Store apps from running in the background, which has to be done individually since Windows 11.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablebgapps"
  },
  "WPFTweaksDisableFSO": {
    "Content": "Fullscreen Optimizations - Disable",
    "Description": "Disables FSO in all applications. NOTE: This will disable Color Management in Exclusive Fullscreen.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_DXGIHonorFSEWindowsCompatible",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablefso"
  },
  "WPFTweaksDisableExplorerAutoDiscovery": {
    "Content": "File Explorer Automatic Folder Discovery - Disable",
    "Description": "Windows Explorer automatically tries to guess the type of the folder based on its contents, slowing down the browsing experience. WARNING! Will disable File Explorer grouping.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disableexplorerautodiscovery"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "BSoD Verbose Mode",
    "Description": "Gives more information when you blue screen.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/detailedbsod"
  },
  "WPFToggleBatteryPercentage": {
    "Content": "System Tray Battery Percentage",
    "Description": "Shows numeric battery percentage next to the battery icon in the system tray.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "IsBatteryPercentageEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/batterypercentage"
  },
  "WPFToggleDarkMode": {
    "Content": "Dark Theme for Windows",
    "Description": "Dark Mode for the system and applications.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/darkmode"
  },
  "WPFToggleShowExt": {
    "Content": "File Explorer File Extensions",
    "Description": "Shows .file extensions in Explorer (.exe, .png, etc.)",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/showext"
  },
  "WPFToggleHiddenFiles": {
    "Content": "File Explorer Hidden Files",
    "Description": "Reveals hidden files in Explorer.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hiddenfiles"
  },
  "WPFToggleVerboseLogon": {
    "Content": "Logon Verbose Mode",
    "Description": "Show detailed messages during startup/shutdown.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/verboselogon"
  },
  "WPFToggleNewOutlook": {
    "Content": "Microsoft Outlook New Version",
    "Description": "This will ensures the classic Outlook application is used.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "UseNewOutlook",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "HideNewOutlookToggle",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "DoNewOutlookAutoMigration",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "NewOutlookMigrationUserSetting",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/newoutlook"
  },
  "WPFToggleScrollbars": {
    "Content": "Scrollbars Always Visible",
    "Description": "If enabled, scrollbars will always be visible. If disabled, Windows will automatically hide scrollbars when not in use.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility",
        "Name": "DynamicScrollbars",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/scrollbars"
  },
  "WPFToggleMultiplaneOverlay": {
    "Content": "Multiplane Overlay",
    "Description": "Multiplane Overlay compose multiple image layers, which can sometimes cause issues with graphics cards.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
        "Name": "OverlayTestMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "5",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
        "Name": "DisableOverlays",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/multiplaneoverlay"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "Mouse Acceleration",
    "Description": "Makes it so Cursor movement is affected by the speed of your physical mouse movements.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/mouseacceleration"
  },
  "WPFToggleNumLock": {
    "Content": "Num Lock on Startup",
    "Description": "Toggle the Num Lock key state when your computer starts.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/numlock"
  },
  "WPFToggleWindowSnapping": {
    "Content": "Window Snapping",
    "Description": "Toggles the window snapping feature when dragging windows.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "WindowArrangementActive",
        "Value": "1",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/windowsnapping"
  },
  "WPFToggleStandbyFix": {
    "Content": "S0 Sleep Network Connectivity",
    "Description": "Toggles network connectivity during S0 Sleep which is low power idle in modern laptops.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
        "Name": "ACSettingIndex",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/standbyfix"
  },
  "WPFToggleS3Sleep": {
    "Content": "S3 Sleep",
    "Description": "Toggles between Modern Standby and S3 Sleep, which cuts off power to the CPU while continuing to refresh the memory.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
        "Name": "PlatformAoAcOverride",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/s3sleep"
  },
  "WPFToggleHideSettingsHome": {
    "Content": "Settings Home Page",
    "Description": "Toggles the Home Page in the Windows Settings app.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "show:home",
        "Type": "String",
        "OriginalValue": "hide:home",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hidesettingshome"
  },
  "WPFToggleBingSearch": {
    "Content": "Start Menu Bing Search",
    "Description": "Toggles Bing web search results in Windows Search.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/bingsearch"
  },
  "WPFToggleLoginBlur": {
    "Content": "Logon Screen Acrylic Blur",
    "Description": "Toggles the acrylic blur effect on login screen background.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "DisableAcrylicBackgroundOnLogon",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/loginblur"
  },
  "WPFTweaksDisableLockscreen": {
    "Content": "Lock Screen - Disable",
    "Description": "Skips the lock screen entirely and goes directly to the sign-in screen on boot and wake.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
        "Name": "NoLockScreen",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/disablelockscreen"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "Start Menu Recommendations",
    "Description": "Toggles the recommendations section in the Start Menu. WARNING: This will also disable Windows Spotlight on your Lock Screen as a side effect.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/startmenurecommendations"
  },
  "WPFToggleStickyKeys": {
    "Content": "Sticky Keys",
    "Description": "Toggles the Sticky Keys, which activate when clicking shift rapidly.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "506",
        "Type": "DWord",
        "OriginalValue": "58",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/stickykeys"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "Taskbar Centered Icons",
    "Description": "Toggles the Taskbar alignment either to the left or center.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbaralignment"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "Taskbar Search Icon",
    "Description": "Toggles the Search Button on the Taskbar.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbarsearch"
  },
  "WPFToggleTaskView": {
    "Content": "Taskbar Task View Icon",
    "Description": "Toggles the Task View Button in the Taskbar.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskview"
  },
  "WPFToggleGameMode": {
    "Content": "Game Mode",
    "Description": "Toggles Windows prioritizes gaming performance by allocating system resources to games.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AllowAutoGameMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AutoGameModeEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/gamemode"
  },
  "WPFToggleLongPaths": {
    "Content": "Enable Long Paths",
    "Description": "Toggles support for file paths longer than 260 characters in Explorer.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        "Name": "LongPathsEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/longpaths"
  },
  "WPFOOSUbutton": {
    "Content": "O&O ShutUp10++ - Run",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Type": "Button",
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/oosubutton"
  },
  "WPFchangedns": {
    "Content": "DNS - Set to:",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/changedns"
  },
  "WPFAddUltPerf": {
    "Content": "Ultimate Performance Profile - Enable",
    "category": "Performance Plans - NOT FOR LAPTOPS",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/addultperf"
  },
  "WPFRemoveUltPerf": {
    "Content": "Ultimate Performance Profile - Disable",
    "category": "Performance Plans - NOT FOR LAPTOPS",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/removeultperf"
  }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinUtility"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="SingleBorderWindow"
        Width="Auto"
        Height="Auto"
        MinWidth="800"
        MinHeight="600"
        Title="CDVR WinUtil">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10" UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="5"/>
        <Setter Property="Padding" Value="6,4"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <ContentPresenter Content="{TemplateBinding Content}"
                                      VerticalAlignment="Center"
                                      HorizontalAlignment="Left"/>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="TextWrapping" Value="Wrap"/>
        <Setter Property="MaxWidth" Value="{DynamicResource AppEntryNameMaxWidth}"/>
        <!-- Reserve 2 lines' height on every tile, not just names that actually wrap - so a
             long name (e.g. "Streaming Library Manager") wrapping to a second line doesn't
             make just that one tile taller than the rest of the grid. -->
        <Setter Property="MinHeight" Value="{DynamicResource AppEntryNameMinHeight}"/>
    </Style>
    <Style x:Key="AppEntrySubtitleStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntrySubtitleFontSize}"/>
        <Setter Property="FontWeight" Value="Normal"/>
        <Setter Property="Foreground" Value="{DynamicResource ToggleButtonOnColor}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
        <!-- Capped to one line, truncated with an ellipsis instead of wrapping - wrapping
             here made tiles with a long subtitle+handle line taller than the rest of the grid. -->
        <Setter Property="TextWrapping" Value="NoWrap"/>
        <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
        <Setter Property="MaxWidth" Value="{DynamicResource AppEntryNameMaxWidth}"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style x:Key="ComboBoxToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Background="{TemplateBinding Background}" BorderThickness="0">
                            <ContentPresenter/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth"   Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border Name="OuterBorder"
                                    BorderBrush="{DynamicResource BorderColor}"
                                    BorderThickness="1"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}"
                                    Background="{TemplateBinding Background}">
                                <ToggleButton Name="ToggleButton"
                                              Style="{StaticResource ComboBoxToggleButtonStyle}"
                                              Background="Transparent"
                                              BorderThickness="0"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              ClickMode="Press">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0"
                                                   Text="{TemplateBinding SelectionBoxItem}"
                                                   Foreground="{TemplateBinding Foreground}"
                                                   Background="Transparent"
                                                   HorizontalAlignment="Left" VerticalAlignment="Center"
                                                   Margin="6,3,2,3"/>
                                        <Path Grid.Column="1"
                                              Data="M 0,0 L 8,0 L 4,5 Z"
                                              Fill="{TemplateBinding Foreground}"
                                              Width="8" Height="5"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Center"
                                              Stretch="Uniform"
                                              Margin="4,0,6,0"/>
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}"/>
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="ContentTemplate">
                <Setter.Value>
                    <DataTemplate>
                        <TextBlock Text="{Binding}" Background="Transparent"
                                   Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ComboBoxItem}}"/>
                    </DataTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <Style x:Key="TabToggleButton" TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Content" Value=""/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="ButtonGlow"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonForegroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <Border Name="BackgroundBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonBackgroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                        <ContentPresenter
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"
                                            Margin="10,2,10,2"/>
                                    </Border>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink"/>
                                <Setter Property="BorderThickness" Value="2"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent"/>
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Cut"/>
                                                    <MenuItem Command="Copy" Header="Copy"/>
                                                    <MenuItem Command="Paste" Header="Paste"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="RoundedProgressBarStyle" TargetType="ProgressBar">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border CornerRadius="4" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1">
                            <Grid ClipToBounds="True">
                                <Border Name="PART_Track" CornerRadius="4" Background="Transparent"/>
                                <Border Name="PART_Indicator" CornerRadius="4" Background="{DynamicResource ProgressBarForegroundColor}" HorizontalAlignment="Left"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Filter Chip Style — used by the Install tab category filter buttons -->
        <Style x:Key="FilterChipStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Margin" Value="2"/>
            <Setter Property="Padding" Value="12,0,12,0"/>
            <Setter Property="Width" Value="Auto"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ChipBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{DynamicResource ButtonBorderThickness}"
                                CornerRadius="{DynamicResource ButtonCornerRadius}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="&#x26A0; Offline Mode - No Internet Connection" Foreground="White" FontWeight="Bold"
                HorizontalAlignment="Center" FontSize="13" Background="Transparent"/>
        </Border>
        <Grid Grid.Row="1" Background="{DynamicResource MainBackgroundColor}">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/> <!-- Navigation buttons -->
                <ColumnDefinition Width="*"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Navigation Buttons Panel -->
            <StackPanel Name="NavDockPanel" Orientation="Horizontal" Grid.Column="0" VerticalAlignment="Center" Margin="5,5,10,5">
                <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
                </StackPanel>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab1BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" >
                            <Underline>I</Underline>nstall
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,10,0" MinWidth="120" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Stretch">
                    <Grid>
                        <TextBox
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Stretch"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,30,0"
                            ToolTip="Press Ctrl-F and type app name to filter application list below. Press Esc to reset the filter">
                        </TextBox>
                        <TextBlock
                            Name="SearchBarIcon"
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Right"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    Margin="0,0,20,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="Change the WinUtil UI Theme"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Auto" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Follow the Windows Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Dark" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Dark Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Light" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Light Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="Adjust Font Scaling for Accessibility"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="Font Scaling"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="Small"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"/>
                                <TextBlock Text="Large"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="Reset"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="Apply"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Import" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Import Configuration from exported file."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Export" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Export Selected Elements and copy execution command to clipboard."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="About" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Documentation" Name="DocumentationMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Sponsors" Name="SponsorMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button
                        Content="&#xE921;"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        ToolTip="Minimize"
                        AutomationProperties.Name="Minimize"
                        Name="WPFMinimizeButton" />
                    <Button
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0,0,0,0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        Name="WPFMaximizeButton">
                        <Button.Style>
                            <Style TargetType="Button" BasedOn="{StaticResource HoverButtonStyle}">
                                <Setter Property="Content" Value="&#xE922;"/>
                                <Setter Property="ToolTip" Value="Maximize"/>
                                <Setter Property="AutomationProperties.Name" Value="Maximize"/>
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType={x:Type Window}}}" Value="Maximized">
                                        <Setter Property="Content" Value="&#xE923;"/>
                                        <Setter Property="ToolTip" Value="Restore"/>
                                        <Setter Property="AutomationProperties.Name" Value="Restore"/>
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </Button.Style>
                    </Button>

                    <Button
                        Content="&#xE8BB;"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        ToolTip="Close"
                        AutomationProperties.Name="Close"
                        Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="0" Padding="-1">
            <TabItem Header="Install" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Quick Category Search Chips -->
                    <WrapPanel Grid.Row="0" Orientation="Horizontal" Margin="5,5,5,5" Name="WPFSearchChips">
                        <TextBlock Text="Filters"
                                   FontSize="{DynamicResource HeaderFontSize}"
                                   FontFamily="{DynamicResource HeaderFontFamily}"
                                   Foreground="{DynamicResource LabelboxForegroundColor}"
                                   Background="Transparent"
                                   VerticalAlignment="Center"
                                   Margin="15,0,8,0"/>
                        <Button Name="WPFSearchChipAll"                    Content="All"                                  Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipFoundational"           Content="Foundational"                         Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipChannelsDVR"            Content="Channels DVR"                         Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipChannelsDVRClients"     Content="Channels DVR Windows Clients"         Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipChannelsDVRSources"     Content="Channels DVR Sources (non-Docker)"    Style="{StaticResource FilterChipStyle}"/>
                    </WrapPanel>

                    <Grid Grid.Row="1" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- Window-level progress indicator - visible regardless of active tab -->
        <Border Name="WPFTweaksProgressBar" Grid.Row="3" Background="{DynamicResource MainBackgroundColor}" Visibility="Collapsed" Padding="10,6">
            <StackPanel Orientation="Vertical">
                <TextBlock Name="WPFTweaksProgressLabel" Text="" Foreground="{DynamicResource MainForegroundColor}" FontSize="13" Background="Transparent" Margin="0,0,0,4"/>
                <ProgressBar Name="WPFTweaksProgressValue" Height="6" Minimum="0" Maximum="100" Value="0" Style="{StaticResource RoundedProgressBarStyle}"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>

'@
$WinUtilAutounattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <!--https://schneegans.de/windows/unattend-generator/?LanguageMode=Interactive&ProcessorArchitecture=amd64&BypassRequirementsCheck=true&ComputerNameMode=Random&CompactOsMode=Default&TimeZoneMode=Implicit&PartitionMode=Interactive&DiskAssertionMode=Skip&WindowsEditionMode=Interactive&InstallFromMode=Automatic&PEMode=Default&UserAccountMode=InteractiveLocal&PasswordExpirationMode=Unlimited&LockoutMode=Default&HideFiles=Hidden&ClassicContextMenu=true&LaunchToThisPC=true&ShowEndTask=true&TaskbarSearch=Hide&TaskbarIconsMode=Empty&DisableWidgets=true&LeftTaskbar=true&HideTaskViewButton=true&StartTilesMode=Default&StartPinsMode=Empty&EnableLongPaths=true&HideEdgeFre=true&DisableEdgeStartupBoost=true&DeleteWindowsOld=true&EffectsMode=Default&DeleteEdgeDesktopIcon=true&DesktopIconsMode=Default&StartFoldersMode=Default&WifiMode=Skip&ExpressSettings=DisableAll&LockKeysMode=Configure&CapsLockInitial=Off&CapsLockBehavior=Toggle&NumLockInitial=On&NumLockBehavior=Toggle&ScrollLockInitial=Off&ScrollLockBehavior=Toggle&StickyKeysMode=Disabled&ColorMode=Custom&SystemColorTheme=Dark&AppsColorTheme=Dark&AccentColor=%230078d4&WallpaperMode=Default&LockScreenMode=Default&WdacMode=Skip&AppLockerMode=Skip-->
    <settings pass="offlineServicing"></settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <UseConfigurationSet>false</UseConfigurationSet>
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="generalize"></settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\Specialize.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\DefaultUser.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>6</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>7</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>8</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="auditSystem"></settings>
    <settings pass="auditUser"></settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\FirstLogon.ps1"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
        <ExtractScript>
param(
    [xml]$Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
        </ExtractScript>
        <File path="C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml">
&lt;LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"&gt;
    &lt;CustomTaskbarLayoutCollection PinListPlacement="Replace"&gt;
        &lt;defaultlayout:TaskbarLayout&gt;
            &lt;taskbar:TaskbarPinList&gt;
                &lt;taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" /&gt;
            &lt;/taskbar:TaskbarPinList&gt;
        &lt;/defaultlayout:TaskbarLayout&gt;
    &lt;/CustomTaskbarLayoutCollection&gt;
&lt;/LayoutModificationTemplate&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.vbs">
HKU = &amp;H80000003
Set reg = GetObject("winmgmts://./root/default:StdRegProv")
Set fso = CreateObject("Scripting.FileSystemObject")

If reg.EnumKey(HKU, "", sids) = 0 Then
    If Not IsNull(sids) Then
        For Each sid In sids
            key = sid + "\Software\Policies\Microsoft\Windows\Explorer"
            name = "LockedStartLayout"
            If reg.GetDWORDValue(HKU, key, name, existing) = 0 Then
                reg.SetDWORDValue HKU, key, name, 0
            End If
        Next
    End If
End If
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.xml">
&lt;Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"&gt;
    &lt;Triggers&gt;
        &lt;EventTrigger&gt;
            &lt;Enabled&gt;true&lt;/Enabled&gt;
            &lt;Subscription&gt;&amp;lt;QueryList&amp;gt;&amp;lt;Query Id="0" Path="Application"&amp;gt;&amp;lt;Select Path="Application"&amp;gt;*[System[Provider[@Name='UnattendGenerator'] and EventID=1]]&amp;lt;/Select&amp;gt;&amp;lt;/Query&amp;gt;&amp;lt;/QueryList&amp;gt;&lt;/Subscription&gt;
        &lt;/EventTrigger&gt;
    &lt;/Triggers&gt;
    &lt;Principals&gt;
        &lt;Principal id="Author"&gt;
            &lt;UserId&gt;S-1-5-18&lt;/UserId&gt;
            &lt;RunLevel&gt;LeastPrivilege&lt;/RunLevel&gt;
        &lt;/Principal&gt;
    &lt;/Principals&gt;
    &lt;Settings&gt;
        &lt;MultipleInstancesPolicy&gt;IgnoreNew&lt;/MultipleInstancesPolicy&gt;
        &lt;DisallowStartIfOnBatteries&gt;false&lt;/DisallowStartIfOnBatteries&gt;
        &lt;StopIfGoingOnBatteries&gt;false&lt;/StopIfGoingOnBatteries&gt;
        &lt;AllowHardTerminate&gt;true&lt;/AllowHardTerminate&gt;
        &lt;StartWhenAvailable&gt;false&lt;/StartWhenAvailable&gt;
        &lt;RunOnlyIfNetworkAvailable&gt;false&lt;/RunOnlyIfNetworkAvailable&gt;
        &lt;IdleSettings&gt;
            &lt;StopOnIdleEnd&gt;true&lt;/StopOnIdleEnd&gt;
            &lt;RestartOnIdle&gt;false&lt;/RestartOnIdle&gt;
        &lt;/IdleSettings&gt;
        &lt;AllowStartOnDemand&gt;true&lt;/AllowStartOnDemand&gt;
        &lt;Enabled&gt;true&lt;/Enabled&gt;
        &lt;Hidden&gt;false&lt;/Hidden&gt;
        &lt;RunOnlyIfIdle&gt;false&lt;/RunOnlyIfIdle&gt;
        &lt;WakeToRun&gt;false&lt;/WakeToRun&gt;
        &lt;ExecutionTimeLimit&gt;PT72H&lt;/ExecutionTimeLimit&gt;
        &lt;Priority&gt;7&lt;/Priority&gt;
    &lt;/Settings&gt;
    &lt;Actions Context="Author"&gt;
        &lt;Exec&gt;
            &lt;Command&gt;C:\Windows\System32\wscript.exe&lt;/Command&gt;
            &lt;Arguments&gt;C:\Windows\Setup\Scripts\UnlockStartLayout.vbs&lt;/Arguments&gt;
        &lt;/Exec&gt;
    &lt;/Actions&gt;
&lt;/Task&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\SetStartPins.ps1">
$json = '{"pinnedList":[]}';
if( [System.Environment]::OSVersion.Version.Build -lt 20000 ) {
    return;
}
$key = 'Registry::HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start';
New-Item -Path $key -ItemType 'Directory' -ErrorAction 'SilentlyContinue';
Set-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins' -Value $json -Type 'String';
        </File>
        <File path="C:\Windows\Setup\Scripts\SetColorTheme.ps1">
$lightThemeSystem = 0;
$lightThemeApps = 0;
$accentColorOnStart = 0;
$enableTransparency = 0;
$htmlAccentColor = '#0078D4';
&amp; {
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
        Force = $true;
        Type = 'DWord';
    };
    Set-ItemProperty @params -Name 'SystemUsesLightTheme' -Value $lightThemeSystem;
    Set-ItemProperty @params -Name 'AppsUseLightTheme' -Value $lightThemeApps;
    Set-ItemProperty @params -Name 'ColorPrevalence' -Value $accentColorOnStart;
    Set-ItemProperty @params -Name 'EnableTransparency' -Value $enableTransparency;
};
&amp; {
    Add-Type -AssemblyName 'System.Drawing';
    $accentColor = [System.Drawing.ColorTranslator]::FromHtml( $htmlAccentColor );

    function ConvertTo-DWord {
        param(
            [System.Drawing.Color]
            $Color
        );

        [byte[]]$bytes = @(
            $Color.R;
            $Color.G;
            $Color.B;
            $Color.A;
        );
        return [System.BitConverter]::ToUInt32( $bytes, 0);
    }

    $startColor = [System.Drawing.Color]::FromArgb( 0xD2, $accentColor );
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';
        Name = 'AccentPalette';
    };
    $palette = Get-ItemPropertyValue @params;
    $index = 20;
    $palette[ $index++ ] = $accentColor.R;
    $palette[ $index++ ] = $accentColor.G;
    $palette[ $index++ ] = $accentColor.B;
    $palette[ $index++ ] = $accentColor.A;
    Set-ItemProperty @params -Value $palette -Type 'Binary' -Force;
};
        </File>
        <File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
    {
        reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f;
    };
    {
        net.exe accounts /maxpwage:UNLIMITED;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f;
        [System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' );
    };
    {
        Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UnlockStartLayout.xml' -Raw );
    };
    {
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
    };
    {
        Remove-Item -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk' -ErrorAction 'SilentlyContinue' -Verbose;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v StartupBoostEnabled /t REG_DWORD /d 0 /f;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetStartPins.ps1';
    };
    {
        reg.exe add "HKU\.DEFAULT\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\Specialize.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
    {
        [System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 );
    };
    {
        Remove-Item -Path "${env:USERPROFILE}\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
        Remove-Item -Path "$env:HOMEDRIVE\Users\Default\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
    };
    {
        $taskbarPath = "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar";
        if( Test-Path $taskbarPath ) {
            Get-ChildItem -Path $taskbarPath -File | Remove-Item -Force;
        }
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesRemovedChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'Favorites' -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetColorTheme.ps1';
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /v Enabled /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v AllAppsViewMode /t REG_DWORD /d 2 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_AccountNotifications /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowAllPinsList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowFrequentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowRecentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackDocs /t REG_DWORD /d 0 /f;
    };
    {
        Restart-Computer -Force;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "$env:TEMP\UserOnce.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
    {
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "StartLayoutFile" /t REG_SZ /d "C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml" /f;
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "LockedStartLayout" /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f;
    };
    {
        foreach( $root in 'Registry::HKU\.DEFAULT', 'Registry::HKU\DefaultUser' ) {
          Set-ItemProperty -LiteralPath "$root\Control Panel\Keyboard" -Name 'InitialKeyboardIndicators' -Type 'String' -Value 2 -Force;
        }
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle \""Normal\"" -ExecutionPolicy \""Unrestricted\"" -NoProfile -File \""C:\Windows\Setup\Scripts\UserOnce.ps1\""" /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\DefaultUser.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
    {
        Remove-Item -LiteralPath @(
          'C:\Windows\Panther\unattend.xml';
          'C:\Windows\Panther\unattend-original.xml';
          'C:\Windows\Setup\Scripts\Wifi.xml';
          'C:\Windows.old';
        ) -Recurse -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f;
        reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;
        $services = @{ BITS = 'Manual'; wuauserv = 'Manual'; UsoSvc = 'Automatic'; WaaSMedicSvc = 'Manual' };
        foreach ($name in $services.Keys) {
            Set-Service -Name $name -StartupType $services[$name] -ErrorAction SilentlyContinue;
        }
    };
    {
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /v IsEducationEnvironment /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
    };
    {
        $recallFeature = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -like 'Recall' };
        if( $recallFeature ) {
            Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -ErrorAction SilentlyContinue;
        }
    };
    {
        $viveDir = Join-Path $env:TEMP 'ViVeTool';
        $viveZip = Join-Path $env:TEMP 'ViVeTool.zip';
        Invoke-WebRequest 'https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip' -OutFile $viveZip;
        Expand-Archive -Path $viveZip -DestinationPath $viveDir -Force;
        Remove-Item -Path $viveZip -Force;
        Start-Process -FilePath (Join-Path $viveDir 'ViVeTool.exe') -ArgumentList '/disable /id:47205210' -Wait -NoNewWindow;
        Remove-Item -Path $viveDir -Recurse -Force;
    };
    {
        Start-Process C:\Windows\System32\OneDriveSetup.exe -ArgumentList /uninstall
    };
    {
        if( (Get-BitLockerVolume -MountPoint $Env:SystemDrive).ProtectionStatus -eq 'On' ) {
            Disable-BitLocker -MountPoint $Env:SystemDrive;
        }
    };
    {
        if( (bcdedit | Select-String 'path').Count -eq 2 ) {
            bcdedit /set `{bootmgr`} timeout 0;
        }
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\FirstLogon.log";
        </File>
    </Extensions>
</unattend>

'@
# Console rendering of the Channels logo (getchannels.com/a/images/channels-logo.svg):
# a white-outlined frame around six vertical color bars (yellow, green, teal, mauve,
# coral, blue), with a small chevron peak above - reproduced here with Write-Host
# -ForegroundColor per segment since a plain heredoc can't carry per-character color.
#
# Sized so the frame itself (border to border) reads as a 16:9 TV rectangle once rendered,
# not just in character-cell counts: a monospace terminal cell is roughly twice as tall as
# it is wide (~0.5 width:height), so matching a 16:9 on-screen ratio needs about 3.56 text
# columns per text row ((16/9) / 0.5), not 1:1 - hence far more columns than rows below.
$channelsLogoBarColors = @('Yellow', 'Green', 'Cyan', 'Magenta', 'Red', 'Blue')
$channelsLogoBarChar = [char]0x2588 # █
$channelsLogoBarWidth = 4
$channelsLogoBarGap = 1
$channelsLogoLeftPad = 2
$channelsLogoRightPad = 2
$channelsLogoLeftMargin = "   "
$channelsLogoCharAspect = 0.5 # typical monospace terminal cell width:height

$channelsLogoInnerWidth = ($channelsLogoBarWidth * $channelsLogoBarColors.Count) +
    ($channelsLogoBarGap * ($channelsLogoBarColors.Count - 1)) +
    $channelsLogoLeftPad + $channelsLogoRightPad
$channelsLogoFrameWidth = $channelsLogoInnerWidth + 2

$channelsLogoTargetFrameRows = [math]::Round($channelsLogoFrameWidth / ((16 / 9) / $channelsLogoCharAspect))
$channelsLogoBarRows = [math]::Max(1, $channelsLogoTargetFrameRows - 4) # - 2 border rows, - 2 blank padding rows

$channelsLogoPeakTop = "/\"
$channelsLogoPeakBottom = "/  \"
$channelsLogoPeakTopPad = [math]::Floor(($channelsLogoFrameWidth - $channelsLogoPeakTop.Length) / 2)
$channelsLogoPeakBottomPad = [math]::Floor(($channelsLogoFrameWidth - $channelsLogoPeakBottom.Length) / 2)

Write-Host ""
Write-Host ($channelsLogoLeftMargin + (" " * $channelsLogoPeakTopPad) + $channelsLogoPeakTop) -ForegroundColor White
Write-Host ($channelsLogoLeftMargin + (" " * $channelsLogoPeakBottomPad) + $channelsLogoPeakBottom) -ForegroundColor White
Write-Host ($channelsLogoLeftMargin + "+" + ("-" * $channelsLogoInnerWidth) + "+") -ForegroundColor White
Write-Host ($channelsLogoLeftMargin + "|" + (" " * $channelsLogoInnerWidth) + "|") -ForegroundColor White
for ($row = 0; $row -lt $channelsLogoBarRows; $row++) {
    Write-Host ($channelsLogoLeftMargin + "|" + (" " * $channelsLogoLeftPad)) -NoNewline -ForegroundColor White
    for ($i = 0; $i -lt $channelsLogoBarColors.Count; $i++) {
        Write-Host ([string]$channelsLogoBarChar * $channelsLogoBarWidth) -NoNewline -ForegroundColor $channelsLogoBarColors[$i]
        if ($i -lt $channelsLogoBarColors.Count - 1) { Write-Host (" " * $channelsLogoBarGap) -NoNewline }
    }
    Write-Host ((" " * $channelsLogoRightPad) + "|") -ForegroundColor White
}
Write-Host ($channelsLogoLeftMargin + "|" + (" " * $channelsLogoInnerWidth) + "|") -ForegroundColor White
Write-Host ($channelsLogoLeftMargin + "+" + ("-" * $channelsLogoInnerWidth) + "+") -ForegroundColor White
Write-Host ""
Write-Host "======CDVR WinUtil========"
Write-Host "=Channels DVR Installer==="
Write-Host "(fork of ChrisTitusTech/winutil)"

Remove-Variable -Name channelsLogo* -ErrorAction SilentlyContinue

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object {
    $sync.configs.appxHashtable[$_.Name] = $_.Value
}
$sync.preferences.theme = "Auto"
$sync.preferences.packagemanager = "Winget"

if ($Preset) {
    Initialize-WinUtilRunspacePool | Out-Null

    # Selects the tweaks from $Preset varible
    Update-WinUtilSelections -flatJson $sync.configs.preset.$Preset

    # Run tweaks that were selected by Update-WinUtilSelections
    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

if ($Config) {
    Initialize-WinUtilRunspacePool | Out-Null

    Invoke-WPFImpex -type "import" -Config $Config

    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting WinUtil..." -ForegroundColor Red
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        $null = $hwnd, $wParam, $lParam
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Build only the default tab before first paint; other tabs initialize on first activation.
$sync.InitializedTabs = @{}
Initialize-WinUtilTabContent -TabName "Install"

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Choco"
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Winget"
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

    }
}

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        $keyEventArgs = $_
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
    $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
        $keyEventArgs = $_
        switch ($_.Key) {
            { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
            { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
$sync["Form"].Add_PreviewMouseWheel({
    if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
})

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            }
            else{
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            }
    }
})

$sync["Form"].Add_Deactivated({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height
        $sync.Form.MinWidth = [Math]::Min([double]$sync.Form.MinWidth, [double]$screenWidth)

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        }
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications."

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "Offline mode detected - Install tab disabled." -ForegroundColor Yellow
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab1BT"  # Default to install tab
    }

    $sync["Form"].Focus()
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true }) | Out-Null
})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Category $sync.SearchBar.Tag
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "AppX" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Tag -ne $sync.SearchBar.Text) {
        $sync.SearchBar.Tag = $null
    }

    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
        $sync.SearchBarIcon.Visibility = "Collapsed"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
        $sync.SearchBarIcon.Visibility = "Visible"
    }

    # Category chip handlers apply their filter immediately.
    if ($sync.SearchBar.Tag -eq $sync.SearchBar.Text) {
        return
    }

    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

# Quick Category Search Chips
$sync["WPFSearchChipAll"].Add_Click({ Set-WinUtilAppCategoryFilter })
$sync["WPFSearchChipFoundational"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Foundational" })
$sync["WPFSearchChipChannelsDVR"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Channels DVR" })
$sync["WPFSearchChipChannelsDVRClients"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Channels DVR Windows Clients" })
$sync["WPFSearchChipChannelsDVRSources"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Channels DVR Sources (non-Docker)" })

$sync["Form"].Add_Loaded({
    param($e)
    $null = $e
    $sync.Form.MinWidth = "1150"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
$NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null
Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
CDVR WinUtil is a Channels DVR-focused fork of WinUtil.
Fork      : <a href="https://github.com/bnhf/cdvr-winutil">bnhf/cdvr-winutil</a>

Original WinUtil:
Author   : <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
UI       : <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
Runspace : <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>
GitHub   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Version  : <a href="https://github.com/ChrisTitusTech/winutil/releases/tag/$($sync.version)">$($sync.version)</a>
"@
    Show-CustomDialog -Title "About" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process "https://winutil.christitus.com/"
})
$sync["SponsorMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
<a href="https://github.com/sponsors/ChrisTitusTech">Current sponsors for ChrisTitusTech:</a>
"@
    $authorInfo += "`n"
    try {
        $sponsors = Invoke-WinUtilSponsors
        foreach ($sponsor in $sponsors) {
            $authorInfo += "<a href=`"https://github.com/sponsors/ChrisTitusTech`">$sponsor</a>`n"
        }
    } catch {
        $authorInfo += "An error occurred while fetching or processing the sponsors: $_`n"
    }
    Show-CustomDialog -Title "Sponsors" -Message $authorInfo -EnableScroll $true
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

function Remove-WinUtilTempScript {
    <#
    .SYNOPSIS
        Removes the temporary script downloaded by windev.ps1.

    .DESCRIPTION
        Deletes the current script only when it is a winutil-*.ps1 file in
        the system temporary directory. This preserves normal file-backed
        and in-memory WinUtil launches.
    #>

    $scriptPath = $PSCommandPath
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')

    if (
        $scriptPath -and
        [IO.Path]::GetDirectoryName($scriptPath) -eq $tempPath -and
        [IO.Path]::GetFileName($scriptPath) -like 'winutil-*.ps1'
    ) {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

# ──────────────────────────────────────────────────────────────────────────────

$sync["Form"].ShowDialog() | out-null
Remove-WinUtilTempScript
Stop-Transcript

