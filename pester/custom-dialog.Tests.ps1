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
    # allows only one per process, so this is guarded rather than unconditional. ShutdownMode
    # defaults to OnLastWindowClose, which silently broke every test after the first one in this
    # file: closing test 1's dialog (the only open window at the time) triggered an automatic
    # Application.Shutdown(), leaving later tests' ShowDialog() calls opening a window that
    # never actually joined a live, running application - Application.Current.Windows read back
    # empty, so nothing was found to inspect or close (isolating and re-running any single test
    # after the first passed, since then it WAS the first window again).
    if (-not [System.Windows.Application]::Current) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
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

    # Walks the dialog's fixed visual tree (Window -> Border -> Grid) to find the message
    # TextBlock - the first TextBlock inside the Grid's row-1 content whose own text/inline runs
    # aren't a per-item Name/Description row (those live in their own nested StackPanel).
    function script:Get-WinUtilDialogMessageText {
        param($Window)

        $grid = $Window.Content.Child
        $row1Content = $grid.Children | Where-Object { [Windows.Controls.Grid]::GetRow($_) -eq 1 } | Select-Object -First 1
        $contentPanel = if ($row1Content -is [System.Windows.Controls.ScrollViewer]) { $row1Content.Content } else { $row1Content }
        $messageTextBlock = $contentPanel.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } | Select-Object -First 1

        ($messageTextBlock.Inlines | ForEach-Object {
            # A Hyperlink has no direct .Text property (unlike Run) - its own text lives in its
            # Inlines/ContentStart..ContentEnd range instead.
            if ($_ -is [Windows.Documents.Hyperlink]) {
                (New-Object Windows.Documents.TextRange($_.ContentStart, $_.ContentEnd)).Text
            } else {
                $_.Text
            }
        }) -join ""
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

    It "renders a plain message with no hyperlinks exactly once, not duplicated" {
        # Regression guard for the actual reported bug: a message with NO "<a href>" hyperlinks
        # left $lastPos at its initial 0, so BOTH "add remaining text after the last hyperlink"
        # (0 < Message.Length, true) AND "no matches, add the entire message" (also true) fired -
        # the whole message got added to Inlines twice. Invisible for every earlier caller
        # (About/Sponsors), which always included at least one hyperlink, so the "no matches"
        # branch never ran for them - only surfaced once a plain-text message (the uninstall
        # confirmation) was used for the first time.
        #
        # $textBox.Value gets mutated (not a plain variable reassigned) for the same reason
        # Show-CustomDialog's own $resultBox exists - see that function's inline comment: a
        # scriptblock assigning to a same-named variable creates a new local one rather than
        # mutating the enclosing scope's, so only mutating a shared object's property actually
        # propagates the captured text back out to the assertion below.
        $textBox = [pscustomobject]@{ Value = $null }
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $timer.Add_Tick({
            $timer.Stop()
            foreach ($window in [System.Windows.Application]::Current.Windows) {
                $textBox.Value = Get-WinUtilDialogMessageText -Window $window
                $window.Close()
            }
        })
        $timer.Start()

        $plainMessage = "This will uninstall the following applications:"
        Show-CustomDialog -Title "Are you sure?" -Message $plainMessage -Buttons YesNo | Out-Null

        $textBox.Value | Should -Be $plainMessage
    }

    It "renders a message with a hyperlink exactly once too, trailing text included" {
        $textBox = [pscustomobject]@{ Value = $null }
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $timer.Add_Tick({
            $timer.Stop()
            foreach ($window in [System.Windows.Application]::Current.Windows) {
                $textBox.Value = Get-WinUtilDialogMessageText -Window $window
                $window.Close()
            }
        })
        $timer.Start()

        $messageWithLink = 'Visit <a href="https://example.com">our site</a> for more info.'
        Show-CustomDialog -Title "About" -Message $messageWithLink | Out-Null

        $textBox.Value | Should -Be "Visit our site for more info."
    }
}
