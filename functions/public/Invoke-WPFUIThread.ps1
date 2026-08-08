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
