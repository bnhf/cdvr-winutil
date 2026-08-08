function Invoke-WPFUIThread ($ScriptBlock) {
    <#
    .SYNOPSIS
        Runs a scriptblock synchronously on the UI thread and returns its result.

    .DESCRIPTION
        Cast to Func[object] rather than Action - Action forces a void return, discarding
        anything the scriptblock produces. Existing callers already ignore the return value, so
        this is purely additive: it lets a caller in the background runspace show a modal (e.g.
        a Yes/No confirmation) and get the answer back, which Action couldn't do.
    #>
    $sync.form.Dispatcher.Invoke([Func[object]]$ScriptBlock)
}
