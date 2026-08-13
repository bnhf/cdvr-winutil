function Open-WinUtilLink {
    <#
    .SYNOPSIS
        Opens a URL, file, or shell path (e.g. an app's web UI, its homepage, or a Start Menu
        shortcut target) at the user's normal integrity level, not inheriting WinUtil's own
        elevated context.

    .DESCRIPTION
        WinUtil always self-elevates at startup (WSL2/Docker/Chocolatey genuinely need admin),
        but every UI entry point that opens a link - the app popup's "Open" and "Info" buttons,
        and hyperlinks inside message dialogs - previously called Start-Process directly, which
        inherits that elevated token. Confirmed live: this launches the user's default browser,
        or the target app itself, with administrator rights every time - for something as
        routine as viewing an app's homepage or its already-running web dashboard. Browsers in
        particular actively discourage running elevated (extensions and some sites behave
        differently, and it needlessly runs untrusted web content with an admin token).

        De-elevated via Start-WinUtilProcessAsStandardUserNoWait, the same scheduled-task
        technique already used for de-elevating installer launches - Task Scheduler's "start a
        program" action resolves its target through the same shell association mechanism as
        Start-Process, so a URL or shell:AppsFolder path works here exactly like a plain .exe
        path does elsewhere. Falls back to a normal (elevated) Start-Process if de-elevation
        itself fails, so a link still opens rather than silently doing nothing.
    #>
    param(
        # Not Mandatory: PowerShell's own Mandatory-parameter binding rejects an empty string
        # before the function body ever runs (and would interactively prompt for a $null one),
        # which defeats the graceful no-op below for a caller whose target genuinely may be
        # unset (e.g. an app with no declared webui and no matching Start Menu shortcut).
        [string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return
    }

    if (-not (Start-WinUtilProcessAsStandardUserNoWait -FilePath $Target)) {
        Start-Process -FilePath $Target
    }
}
