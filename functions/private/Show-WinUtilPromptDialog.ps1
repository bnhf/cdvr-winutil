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
        Array of objects with at least a "name" and "label"; optional "secret" (bool) masks the field.

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
        $stack.Children.Add($msgBlock)
    }

    $inputs = @{}
    foreach ($prompt in $Prompts) {
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $prompt.label
        $label.Margin = New-Object Windows.Thickness(0, 6, 0, 2)
        $stack.Children.Add($label)

        if ($prompt.secret) {
            $field = New-Object Windows.Controls.PasswordBox
        } else {
            $field = New-Object Windows.Controls.TextBox
        }
        $field.Margin = New-Object Windows.Thickness(0, 0, 0, 4)
        $stack.Children.Add($field)
        $inputs[$prompt.name] = $field
    }

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $buttonPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    $buttonPanel.Margin = New-Object Windows.Thickness(0, 12, 0, 0)
    $stack.Children.Add($buttonPanel)

    $script:winutilPromptResult = $null

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Content = "Cancel"
    $cancelButton.Width = 80
    $cancelButton.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
    $cancelButton.Add_Click({
        $script:winutilPromptResult = $null
        $dialog.Close()
    }.GetNewClosure())
    $buttonPanel.Children.Add($cancelButton)

    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.Width = 80
    $okButton.Background = $ButtonBackgroundColor
    $okButton.Foreground = $ButtonForegroundColor
    $okButton.IsDefault = $true
    $okButton.Add_Click({
        $result = @{}
        foreach ($entry in $inputs.GetEnumerator()) {
            $field = $entry.Value
            $result[$entry.Key] = if ($field -is [Windows.Controls.PasswordBox]) { $field.Password } else { $field.Text }
        }
        $script:winutilPromptResult = $result
        $dialog.Close()
    }.GetNewClosure())
    $buttonPanel.Children.Add($okButton)

    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $script:winutilPromptResult = $null
            $dialog.Close()
        }
    })

    $dialog.ShowDialog() | Out-Null
    return $script:winutilPromptResult
}
