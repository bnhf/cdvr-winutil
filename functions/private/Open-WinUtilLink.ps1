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
        technique already used for de-elevating installer launches - but routed through
        explorer.exe as the actual Execute target, with Target passed as its argument, rather
        than passing Target directly as -FilePath. An earlier version did the latter, reasoning
        that Task Scheduler's "start a program" action would resolve a URL or shell:AppsFolder
        path via the same shell-association mechanism Start-Process uses - confirmed live that
        this was simply wrong: Task Scheduler's action model expects a real, literal executable
        file and fails with ERROR_FILE_NOT_FOUND for a bare URL, which broke every "Open"/"Info"
        button and every dialog hyperlink using a URL (the majority of them - most apps declare
        a "webui" URL, not a Start Menu shortcut) while silently reporting success, since
        Start-ScheduledTask only confirms the task started, not that its action actually ran.
        explorer.exe is a real executable Task Scheduler CAN launch directly, and explorer.exe
        itself resolves a URL or shell:AppsFolder argument exactly the way Start-Process would
        (confirmed live: this actually opens the target in the default browser/app). Falls back
        to a normal (elevated) Start-Process on $Target directly if de-elevation itself fails -
        that path was never broken, since Start-Process has always correctly resolved URLs and
        shell paths on its own.
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

    if (-not (Start-WinUtilProcessAsStandardUserNoWait -FilePath "$env:WINDIR\explorer.exe" -ArgumentList @($Target))) {
        Start-Process -FilePath $Target
    }
}
