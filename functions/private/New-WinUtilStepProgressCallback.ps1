function New-WinUtilStepProgressCallback {
    <#
    .SYNOPSIS
        Returns a stateful scriptblock that, called with no arguments, returns the next step's
        percent within [StartPercent, EndPercent] - divided evenly across ExpectedSteps calls.

    .DESCRIPTION
        A pure calculator, not the actual -ProgressCallback passed to installer/uninstaller
        functions - it has no dependency on Set-WinUtilTweaksProgressIndicator or any other
        function, only arithmetic and its own closed-over counter state. Callers build the real
        callback around it inline, e.g.:

            $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent $s -EndPercent $e -ExpectedSteps $n
            $callback = { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextStepPercent)) }

        Deliberately kept side-effect-free: an earlier version of this function returned the
        fully-built -ProgressCallback directly (calling Set-WinUtilTweaksProgressIndicator
        itself, via .GetNewClosure() to keep its counter state alive across calls). That worked
        in the running app, where this file and Set-WinUtilTweaksProgressIndicator end up in the
        same compiled script's top-level scope - but confirmed live under Pester, GetNewClosure
        freezes command resolution to whatever scope existed at closure-creation time (inside
        this function's own dot-sourced file), not the caller's scope at invocation time, so a
        Mock of Set-WinUtilTweaksProgressIndicator set up elsewhere (e.g. a test's BeforeAll)
        was never seen - "Set-WinUtilTweaksProgressIndicator is not recognized". Returning only
        the numeric calculator here, with the real function call written inline in the caller's
        own scope (a plain scriptblock, no GetNewClosure needed - it only lives long enough to
        be used within the same loop iteration that creates it), sidesteps the problem entirely:
        commands resolve normally, dynamically, the same way the very first version of this
        progress-bar mechanism did before per-step tracking existed.

        Divides the package's own [StartPercent, EndPercent] slot evenly across ExpectedSteps -
        the actual number of times a given installer function calls -ProgressCallback for one
        package, which is fixed and known per function (e.g. Install-WinUtilProgramDirect always
        calls it exactly twice: downloading, then installing). A wrong ExpectedSteps is a
        cosmetic risk, not a correctness one: too low and the calculator reaches EndPercent
        early then holds there for remaining calls (capped, never exceeds); too high and it just
        doesn't quite reach EndPercent before the caller's own authoritative
        Set-WinUtilTweaksProgressIndicator call after the installer returns snaps it there
        anyway.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [double]$StartPercent,

        [Parameter(Mandatory = $true)]
        [double]$EndPercent,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedSteps
    )

    $state = [pscustomobject]@{ Step = 0 }
    $stepSize = ($EndPercent - $StartPercent) / [Math]::Max(1, $ExpectedSteps)

    return {
        $state.Step++
        [Math]::Min($EndPercent, $StartPercent + ($stepSize * $state.Step))
    }.GetNewClosure()
}
