function Invoke-WPFUIThreadWithResult ($ScriptBlock) {
    <#
    .SYNOPSIS
        Runs a scriptblock synchronously on the UI thread and returns its result.

    .DESCRIPTION
        A separate function from Invoke-WPFUIThread, not a shared implementation switching on a
        parameter - the two must never be interchangeable at existing call sites. Invoke-
        WPFUIThread is called as a bare, uncaptured statement in dozens of places throughout the
        codebase, often mid-function rather than as the last statement; casting that shared
        Dispatcher.Invoke to Func[object] instead of Action made every one of those bare calls
        inject its result into the *enclosing function's* own return value once collected by its
        caller - a real shipped bug (see Invoke-WPFUIThread's own comment for the concrete
        failure). Use this only where the return value is actually consumed, e.g. a background
        runspace showing a modal Yes/No confirmation and needing the answer back.
    #>
    $sync.form.Dispatcher.Invoke([Func[object]]$ScriptBlock)
}
