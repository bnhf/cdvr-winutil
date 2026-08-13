Function Uninstall-WinUtilProgramGithub {
    <#
    .SYNOPSIS
        Uninstalls a "github" install-type package via its own registered Windows uninstaller,
        looked up from the Add/Remove Programs registry by DisplayName - see
        Get-WinUtilProgramUninstallString.ps1 for why this works without a winget/choco id or a
        declared uninstallCommand.

    .DESCRIPTION
        De-elevated and run fire-and-forget, the same way and for the same reason as
        Uninstall-WinUtilProgramDirect's uninstallViaInstaller branch - the uninstaller is
        typically interactive (a confirmation prompt at minimum), so this launches it and moves
        on rather than waiting on it to close.

        The registered UninstallString is run via "cmd.exe /c", not parsed and split into a
        FilePath/ArgumentList pair - it can be a plain quoted exe path, an exe plus extra
        arguments, or an MsiExec.exe /X{GUID} reference, and cmd's own parsing handles all of
        those correctly without needing to know which shape a given installer used, the same
        way Windows' own "Add or Remove Programs" UI runs this value.

        Matches by DisplayName wildcard on the catalog's own "content" field (e.g. "*Clicker*")
        - no separate JSON field needed, since this only depends on what the installer itself
        registered, not anything WinUtil's catalog controls. Confirmed for Clicker specifically
        via its own repo docs: "the installer registers an uninstaller; nothing has to be
        deleted by hand."

        "portable" packages (catalog field "portable": true, e.g. Pluto for Channels) skip all
        of the above - they never register in Add/Remove Programs in the first place (confirmed
        via its own repo docs), so that lookup would always fail for them. Install-WinUtilProgramGithub
        always installs these into Get-WinUtilPortableGithubInstallDir's fixed per-app folder, so
        uninstalling one is the same "stop the process, delete the folder" approach
        Uninstall-WinUtilStreamLinkManager already uses for the same reason.

        Matching the running process by its install-folder Path alone (an earlier version of
        this did only that) isn't reliable for every portable app: confirmed live for Pluto for
        Channels, which - being a large (~200MB) single-file bundle, the standard shape for a
        PyInstaller "onefile" build - can keep its tray-icon process alive under conditions this
        Path check misses (e.g. self-extracted resources reported under a different path).
        Whatever the exact cause, the visible symptom was real and bad: the uninstall logged
        success while a locked file inside the install folder silently made Remove-Item's own
        deletion incomplete (a non-terminating per-item error, not one Remove-Item throws as a
        catchable exception) - so the app kept running (the reported tray icon) AND "Show
        Installed Apps" kept finding it (the folder, and the file the detection check looks
        for, both still there). Now matches by process NAME too (derived from whatever file(s)
        actually exist in the install folder matching the catalog's own assetPattern - the same
        source of truth Test-WinUtilPortableGithubInstalled's own detection uses), waits briefly
        for a just-stopped process to actually release its file handles before deleting, and -
        the fix for the false "uninstalled" success message itself - verifies the folder is
        actually gone afterward rather than assuming Remove-Item's silence means it worked.

        ProgressCallback works the same way as Install-WinUtilProgramDirect's - see that
        function's docstring for why it exists.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    foreach ($package in $Packages) {
        $name = $package.content

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "GitHub uninstall is missing content (display name) to look up."
            continue
        }

        if ($package.portable) {
            Write-WinUtilLog -Component "Package" -Message "Uninstalling $name"
            if ($ProgressCallback) { try { & $ProgressCallback "Uninstalling $name..." } catch {} }
            try {
                $installDir = Get-WinUtilPortableGithubInstallDir -Name $name

                # Process names the app might be running under, derived from whatever's
                # actually on disk (not just the catalog's assetPattern string itself, in case
                # the file was renamed/replaced) - the same folder Install-WinUtilProgramGithub
                # always uses for this app.
                $runningNames = @()
                if ($package.assetPattern -and (Test-Path $installDir)) {
                    $runningNames = @(Get-ChildItem -Path $installDir -Filter $package.assetPattern -ErrorAction SilentlyContinue |
                        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
                }

                $runningInstances = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                    $matchesInstallDir = $false
                    try { $matchesInstallDir = $_.Path -like "$installDir\*" } catch {}
                    $matchesInstallDir -or ($runningNames -contains $_.Name)
                })
                foreach ($runningInstance in $runningInstances) {
                    Stop-Process -Id $runningInstance.Id -Force -ErrorAction SilentlyContinue
                }

                # A just-stopped process doesn't always release its file handles instantly -
                # give it a moment before trying to delete, rather than racing it.
                if ($runningInstances.Count -gt 0) {
                    $deadline = (Get-Date).AddSeconds(5)
                    while ((Get-Date) -lt $deadline -and (@($runningInstances.Id | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -gt 0)) {
                        Start-Sleep -Milliseconds 250
                    }
                }

                if (Test-Path $installDir) {
                    Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
                }

                # Remove-Item on a directory containing a still-locked file reports a
                # non-terminating per-item error, not one this function's own catch below would
                # ever see - checking the result directly is what actually catches that, instead
                # of logging a false "uninstalled" success while the folder (and the app) are
                # still there.
                if (Test-Path $installDir) {
                    Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name uninstall incomplete: $installDir still exists, likely because a file inside it is still in use. Close $name (check the system tray) and try again."
                } else {
                    Write-WinUtilLog -Component "Package" -Message "$name uninstalled."
                }
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall ${name}: $_"
            }
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Looking up $name in Add/Remove Programs"
        if ($ProgressCallback) { try { & $ProgressCallback "Looking up $name..." } catch {} }

        $lookup = Get-WinUtilProgramUninstallString -DisplayNamePattern "*$name*"
        if ([string]::IsNullOrWhiteSpace($lookup.UninstallString)) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Could not uninstall ${name}: $($lookup.Reason)"
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Launching $name's uninstaller - it may ask you to confirm. WinUtil will not wait for it to close."
        if ($ProgressCallback) { try { & $ProgressCallback "Uninstalling $name..." } catch {} }
        try {
            if (-not (Start-WinUtilProcessAsStandardUserNoWait -FilePath "cmd.exe" -ArgumentList @("/c", $lookup.UninstallString))) {
                $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $lookup.UninstallString) -PassThru
                Set-WinUtilProcessForeground -Process $proc
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to launch uninstaller for ${name}: $_"
        }
    }
}
