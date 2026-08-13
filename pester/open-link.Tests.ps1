#===========================================================================
# Tests - Open-WinUtilLink de-elevation
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Open-WinUtilLink.ps1")

    function Start-WinUtilProcessAsStandardUserNoWait { param($FilePath, $ArgumentList) }
}

Describe "Open-WinUtilLink" {
    BeforeEach {
        Mock Start-WinUtilProcessAsStandardUserNoWait { $true }
        Mock Start-Process { }
    }

    It "opens the target de-elevated, not inheriting WinUtil's own elevated context" {
        # Regression guard: the app popup's "Open"/"Info" buttons and dialog hyperlinks used to
        # call Start-Process directly, which inherits WinUtil's own elevated token - confirmed
        # live, this launches the default browser (or the target app) as Administrator for
        # something as routine as viewing a homepage or an already-running local web UI.
        Open-WinUtilLink -Target "http://localhost:8089"

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "http://localhost:8089"
        }
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "falls back to an elevated Start-Process when de-elevation fails" {
        Mock Start-WinUtilProcessAsStandardUserNoWait { $false }

        Open-WinUtilLink -Target "http://localhost:8089"

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "http://localhost:8089"
        }
    }

    It "does nothing for a blank or missing target, rather than launching a bare de-elevated shell" {
        Open-WinUtilLink -Target ""

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 0 -Exactly
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }
}
