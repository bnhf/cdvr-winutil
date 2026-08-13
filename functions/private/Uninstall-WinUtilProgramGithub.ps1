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
