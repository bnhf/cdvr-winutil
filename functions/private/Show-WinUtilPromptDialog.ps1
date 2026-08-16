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
        the entered value meets that length; optional "default" (string) pre-fills a non-secret
        field's text (ignored for secret fields - pre-filling a password field would show a
        stored secret back to whoever's looking at the screen, not a trade worth making for
        typing convenience). Resolving a "default" dynamically (e.g. from an environment
        variable) is the caller's job - see Resolve-WinUtilPackagePrompts - this function only
        ever displays whatever plain string it's handed.

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
            if ($prompt.default) { $field.Text = [string]$prompt.default }
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
