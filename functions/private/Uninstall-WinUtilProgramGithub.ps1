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

        Stopping the running instance is Stop-WinUtilProcessByAssetPattern's job (taskkill's
        /FI IMAGENAME filter, not /IM directly, and not Get-Process/Stop-Process) - see that
        function's own docstring for the full history of why: two PowerShell-side Get-Process
        approaches, then a first taskkill /IM attempt, were all confirmed live to still silently
        fail to stop Pluto for Channels' actual running process. Remove-Item then hit that
        still-open file and failed to fully delete the folder, but that failure is a
        non-terminating per-item error Remove-Item doesn't throw as a catchable exception, so
        the WARN-on-incomplete-deletion check below (this function's other fix) correctly
        reported it as incomplete rather than lying about success - the deletion really was
        incomplete, just for a root cause that took several rounds to actually pin down.

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

                # taskkill terminates synchronously (by the time this returns, a matched process
                # is already gone) - but the OS can lag slightly releasing a just-killed
                # process's file handles/module mappings, so a brief fixed pause before deleting
                # is still worth it, simpler than polling for something taskkill itself doesn't
                # give us a handle to poll.
                if ($package.assetPattern) {
                    Stop-WinUtilProcessByAssetPattern -AssetPattern $package.assetPattern
                    Start-Sleep -Milliseconds 500
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
