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
            $FilePath -eq "$env:WINDIR\explorer.exe" -and (@($ArgumentList) -join "|") -eq "http://localhost:8089"
        }
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "routes the URL through explorer.exe as the actual Task Scheduler action, not the URL directly" {
        # Regression guard for the actual reported bug: an earlier version passed the URL
        # directly as -FilePath, reasoning Task Scheduler would resolve it the way Start-Process
        # does - confirmed live this was wrong (Task Scheduler's action model expects a literal
        # executable file and fails with ERROR_FILE_NOT_FOUND for a bare URL), silently breaking
        # every "Open"/"Info" button and dialog hyperlink that uses a URL - the majority of them
        # - while still reporting success, since Start-ScheduledTask only confirms the task
        # started, not that its action actually ran. explorer.exe is a real executable Task
        # Scheduler can launch, and it resolves a URL argument the same way Start-Process would.
        Open-WinUtilLink -Target "https://github.com/hjdhjd/prismcast"

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "$env:WINDIR\explorer.exe"
        }
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
