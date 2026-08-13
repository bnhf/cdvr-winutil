#===========================================================================
# Tests - New-WinUtilStepProgressCallback
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\New-WinUtilStepProgressCallback.ps1")
}

Describe "New-WinUtilStepProgressCallback" {
    It "advances evenly across the expected number of steps" {
        # Regression guard for the real reported bug: milestone labels were changing, but
        # Percent only ever moved at package start/end - a multi-step single-package install
        # looked exactly like the original "frozen bar" bug, just with the label now changing
        # underneath a still-static bar.
        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent 0 -EndPercent 100 -ExpectedSteps 4

        (& $nextStepPercent) | Should -Be 25
        (& $nextStepPercent) | Should -Be 50
        (& $nextStepPercent) | Should -Be 75
        (& $nextStepPercent) | Should -Be 100
    }

    It "offsets steps within an arbitrary [StartPercent, EndPercent] slot, not just 0-100" {
        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent 50 -EndPercent 100 -ExpectedSteps 2

        (& $nextStepPercent) | Should -Be 75
        (& $nextStepPercent) | Should -Be 100
    }

    It "caps at EndPercent rather than overshooting when called more times than ExpectedSteps" {
        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent 0 -EndPercent 30 -ExpectedSteps 3

        $results = 1..6 | ForEach-Object { & $nextStepPercent }

        $results | Should -Be @(10, 20, 30, 30, 30, 30)
    }

    It "tracks its own step count independently across separate instances" {
        # Each package gets its own freshly-built calculator - confirms the closure state
        # doesn't leak between them.
        $callbackA = New-WinUtilStepProgressCallback -StartPercent 0 -EndPercent 50 -ExpectedSteps 2
        $callbackB = New-WinUtilStepProgressCallback -StartPercent 50 -EndPercent 100 -ExpectedSteps 2

        (& $callbackA) | Should -Be 25
        (& $callbackB) | Should -Be 75
        (& $callbackA) | Should -Be 50
        (& $callbackB) | Should -Be 100
    }

    It "builds a working -ProgressCallback when wrapped inline, the way callers actually use it" {
        # Confirms the documented usage pattern (a plain inline scriptblock around the
        # calculator, not returned as part of this function) actually resolves
        # Set-WinUtilTweaksProgressIndicator correctly - this is exactly the shape that broke
        # under Pester when an earlier version of this function tried to call it via
        # .GetNewClosure() itself instead.
        function Set-WinUtilTweaksProgressIndicator { param($Visible, $Label, $Percent) }
        Mock Set-WinUtilTweaksProgressIndicator { }

        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent 0 -EndPercent 100 -ExpectedSteps 2
        $callback = { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextStepPercent)) }

        & $callback "step 1"
        & $callback "step 2"

        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter { $Percent -eq 50 -and $Label -eq "step 1" }
        Should -Invoke -CommandName Set-WinUtilTweaksProgressIndicator -Times 1 -Exactly -ParameterFilter { $Percent -eq 100 -and $Label -eq "step 2" }
    }
}
