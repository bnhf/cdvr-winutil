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

    .PARAMETER Items
    An optional list of objects (each with a Name and Description property) rendered as a
    clean, properly-themed list below Message - Name bold at full opacity, Description wrapped
    underneath it at reduced opacity for visual hierarchy. Use this instead of trying to fake a
    text table via Select-Object/Out-String in Message: this dialog's TextBlocks use a
    proportional font, so space-padded "columns" in plain text never actually line up.

    .PARAMETER Buttons
    "OK" (default) or "YesNo". In "YesNo" mode the dialog returns the string "Yes" or "No"
    depending on which the user clicked - matches Show-WinUtilMessage's own return convention,
    so callers written against that (e.g. "if ($confirm -eq 'No') { return }") work unchanged.

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

        [bool]$EnableScroll = $false,

        [object[]]$Items,

        [ValidateSet("OK", "YesNo")]
        [string]$Buttons = "OK"
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
    $grid.RowDefinitions.Add($row0) | Out-Null
    $grid.RowDefinitions.Add($row1) | Out-Null
    $grid.RowDefinitions.Add($row2) | Out-Null

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel) | Out-Null
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize)) | Out-Null

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "WinUtil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock) | Out-Null
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
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore))) | Out-Null
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value) | Out-Null
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            Open-WinUtilLink -Target $eventSender.NavigateUri.AbsoluteUri
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

        $messageTextBlock.Inlines.Add($hyperlink) | Out-Null

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Pre-existing bug, confirmed live: a message with NO hyperlinks at all left $lastPos at its
    # initial 0, so "add remaining text after the last hyperlink" (0 < Message.Length, true) AND
    # "no matches, add the entire message" (also true) BOTH fired, adding the whole message to
    # Inlines twice - invisible for every earlier caller (About/Sponsors), which always included
    # at least one hyperlink, so the "no matches" branch never ran for them. These need to be
    # mutually exclusive, not two independent ifs.
    if ($regex.Matches($Message).Count -eq 0) {
        # No hyperlinks at all - add the entire message as plain text, once.
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message))) | Out-Null
    } elseif ($lastPos -lt $Message.Length) {
        # Trailing text after the last hyperlink match, if any.
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter))) | Out-Null
    }

    # Content panel: the message text block, plus (when supplied) a clean Name/Description list
    # below it - real WPF rows with a bold Name and a wrapped, reduced-opacity Description,
    # rather than a space-padded plain-text "table" that only lines up in a monospace font this
    # dialog doesn't use.
    $contentPanel = New-Object Windows.Controls.StackPanel
    $contentPanel.Children.Add($messageTextBlock) | Out-Null

    foreach ($item in $Items) {
        $itemPanel = New-Object Windows.Controls.StackPanel
        $itemPanel.Margin = New-Object Windows.Thickness(10, 8, 10, 0)

        $itemNameBlock = New-Object Windows.Controls.TextBlock
        $itemNameBlock.Text = $item.Name
        $itemNameBlock.FontSize = $FontSize
        $itemNameBlock.FontWeight = [Windows.FontWeights]::Bold
        $itemNameBlock.Foreground = $ForegroundColor
        $itemNameBlock.TextWrapping = [Windows.TextWrapping]::Wrap
        $itemPanel.Children.Add($itemNameBlock) | Out-Null

        if (-not [string]::IsNullOrWhiteSpace($item.Description)) {
            $itemDescriptionBlock = New-Object Windows.Controls.TextBlock
            $itemDescriptionBlock.Text = $item.Description
            $itemDescriptionBlock.FontSize = $FontSize
            $itemDescriptionBlock.Foreground = $ForegroundColor
            $itemDescriptionBlock.Opacity = 0.7
            $itemDescriptionBlock.TextWrapping = [Windows.TextWrapping]::Wrap
            $itemPanel.Children.Add($itemDescriptionBlock) | Out-Null
        }

        $contentPanel.Children.Add($itemPanel) | Out-Null
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $contentPanel
        $grid.Children.Add($scrollViewer) | Out-Null
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($contentPanel) | Out-Null
        [Windows.Controls.Grid]::SetRow($contentPanel, 1)  # Set the row to the second row (0-based index)
    }

    # Button row: a single OK button, or Yes/No side by side. $resultBox is a mutable reference
    # object (not a plain variable) specifically so the click handlers below can communicate
    # their result back out - a plain "$dialogResult = ..." assignment inside a scriptblock
    # creates a new LOCAL variable that shadows the outer one rather than mutating it (only
    # reading an outer variable, like $dialog.Close() elsewhere in this function, resolves
    # through the parent scope automatically; writing to one doesn't). Mutating a property on a
    # shared object, instead of reassigning a variable, is what actually propagates the click
    # result back to the "return $resultBox.Value" after ShowDialog() below. Existing OK-only
    # callers never capture this function's return value, so always returning it here (rather
    # than only in YesNo mode) is a no-op change for them.
    $resultBox = [pscustomobject]@{ Value = "OK" }

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $buttonPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $buttonPanel.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $buttonPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 10)

    if ($Buttons -eq "YesNo") {
        $yesButton = New-Object Windows.Controls.Button
        $yesButton.Content = "Yes"
        $yesButton.FontSize = $FontSize
        $yesButton.Width = 80
        $yesButton.Height = 30
        $yesButton.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
        $yesButton.Background = $buttonBackgroundColor
        $yesButton.Foreground = $buttonForegroundColor
        $yesButton.BorderBrush = $BorderColor
        $yesButton.IsDefault = $true
        $yesButton.Add_Click({
            $resultBox.Value = "Yes"
            $dialog.Close()
        })
        $buttonPanel.Children.Add($yesButton) | Out-Null

        $noButton = New-Object Windows.Controls.Button
        $noButton.Content = "No"
        $noButton.FontSize = $FontSize
        $noButton.Width = 80
        $noButton.Height = 30
        $noButton.Background = $buttonBackgroundColor
        $noButton.Foreground = $buttonForegroundColor
        $noButton.BorderBrush = $BorderColor
        $noButton.IsCancel = $true
        $noButton.Add_Click({
            $resultBox.Value = "No"
            $dialog.Close()
        })
        $buttonPanel.Children.Add($noButton) | Out-Null
    } else {
        $okButton = New-Object Windows.Controls.Button
        $okButton.Content = "OK"
        $okButton.FontSize = $FontSize
        $okButton.Width = 80
        $okButton.Height = 30
        $okButton.Background = $buttonBackgroundColor
        $okButton.Foreground = $buttonForegroundColor
        $okButton.BorderBrush = $BorderColor
        $okButton.IsDefault = $true
        $okButton.Add_Click({
            $dialog.Close()
        })
        $buttonPanel.Children.Add($okButton) | Out-Null
    }

    $grid.Children.Add($buttonPanel) | Out-Null
    [Windows.Controls.Grid]::SetRow($buttonPanel, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog - defaults to "No" in YesNo mode (declining is
    # the safe default for a confirmation), "OK" otherwise, same as the button already would.
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            if ($Buttons -eq "YesNo") { $resultBox.Value = "No" }
            $dialog.Close()
        }
    })

    # Show the custom dialog
    $dialog.ShowDialog() | Out-Null
    return $resultBox.Value
}
