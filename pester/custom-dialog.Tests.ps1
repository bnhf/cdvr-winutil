#===========================================================================
# Tests - Show-CustomDialog Yes/No confirmation and Items list, against a real WPF Dispatcher
#===========================================================================
# ShowDialog() blocks the calling thread until the window closes, so these use a
# DispatcherTimer that fires once the dialog's own modal loop is pumping to close it - the
# timer is what unblocks ShowDialog() and lets the test actually complete. The specific
# "does the Yes/No click result actually propagate out of the function" risk (a PowerShell
# scoping trap - assigning to a variable inside a scriptblock creates a new local one rather
# than mutating the enclosing scope's) was verified separately in isolation against a real
# Button.RaiseEvent before this was wired in; these tests cover the rest: the function builds
# successfully with an Items list and in both button modes, and returns the right default.

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    Add-Type -AssemblyName PresentationFramework
    . (Join-Path $script:repoRoot "functions\private\Show-CustomDialog.ps1")

    # A Window's constructor only auto-registers itself into Application.Current.Windows (used
    # below to find and close the dialog) when an Application instance already exists - WPF
    # allows only one per process, so this is guarded rather than unconditional.
    if (-not [System.Windows.Application]::Current) {
        New-Object System.Windows.Application | Out-Null
    }

    function Invoke-WinUtilAssets { param($Type, $Size) New-Object Windows.Controls.Border }
    function Open-WinUtilLink { param($Target) }

    function script:New-WinUtilDialogBrush {
        param($ColorName = "White")
        New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::$ColorName)
    }

    $script:sync = @{
        Form = [pscustomobject]@{
            Resources = @{
                CustomDialogWidth            = 400
                CustomDialogHeight           = 300
                FontFamily                   = New-Object System.Windows.Media.FontFamily("Segoe UI")
                CustomDialogFontSize         = 12
                CustomDialogFontSizeHeader   = 14
                CustomDialogLogoSize         = 20
                LabelboxForegroundColor      = New-WinUtilDialogBrush
                BorderColor                  = New-WinUtilDialogBrush
                MainForegroundColor          = New-WinUtilDialogBrush
                MainBackgroundColor          = New-WinUtilDialogBrush "Black"
                ButtonInstallForegroundColor = New-WinUtilDialogBrush
                ButtonInstallBackgroundColor = New-WinUtilDialogBrush "Gray"
                LinkForegroundColor          = New-WinUtilDialogBrush "Blue"
                LinkHoverForegroundColor     = New-WinUtilDialogBrush "Cyan"
            }
        }
    }

    # Runs Show-CustomDialog with a timer that auto-closes it shortly after showing, so the
    # blocking ShowDialog() call inside it actually returns and the test can complete.
    function script:Invoke-WinUtilAutoClosingDialog {
        param([hashtable]$DialogParams)

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $timer.Add_Tick({
            $timer.Stop()
            foreach ($window in [System.Windows.Application]::Current.Windows) {
                $window.Close()
            }
        }.GetNewClosure())
        $timer.Start()

        Show-CustomDialog @DialogParams
    }
}

Describe "Show-CustomDialog" {
    It "builds and shows without throwing when given an Items list" {
        # Regression guard: an earlier draft left a stale "$okButton.IsDefault = $true" line
        # after the OK/YesNo button logic was split into two branches - $okButton doesn't exist
        # in YesNo mode, so that line would throw as soon as any YesNo dialog tried to close.
        $items = @(
            [pscustomobject]@{ Name = "Node.js"; Description = "JavaScript runtime required by npm-distributed Channels DVR tools such as Prismcast." }
            [pscustomobject]@{ Name = "Prismcast"; Description = "" }
        )

        {
            Invoke-WinUtilAutoClosingDialog -DialogParams @{
                Title = "Are you sure?"
                Message = "This will uninstall the following applications:"
                Items = $items
                Buttons = "YesNo"
                EnableScroll = $true
            }
        } | Should -Not -Throw
    }

    It "defaults to returning 'OK' when closed without a Yes/No click (OK mode)" {
        $result = Invoke-WinUtilAutoClosingDialog -DialogParams @{
            Title = "About"
            Message = "Just some info."
        }

        $result | Should -Be "OK"
    }

    It "still builds and returns without throwing in YesNo mode when closed without a click" {
        # The window closing via the X/Alt-F4/timer path (not a button click) should fall back
        # to whatever $resultBox.Value already holds, not throw for lack of a click.
        $result = Invoke-WinUtilAutoClosingDialog -DialogParams @{
            Title = "Are you sure?"
            Message = "This will uninstall the following applications:"
            Buttons = "YesNo"
        }

        $result | Should -BeIn @("Yes", "No", "OK")
    }
}
