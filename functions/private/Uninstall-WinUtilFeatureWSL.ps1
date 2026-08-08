Function Uninstall-WinUtilFeatureWSL {
    <#
    .SYNOPSIS
        Uninstalls the WSL2 platform: after confirming with the user, stops and unregisters
        the distro(s) WinUtil's own catalog manages (e.g. Debian) that are actually currently
        registered, then runs "wsl --uninstall".

    .DESCRIPTION
        Only ever unregisters distros declared in WinUtil's own catalog (installType
        "wslDistro") - never anything else that might be registered on this machine, since that
        data isn't ours to delete. Unregistering permanently deletes that distro's filesystem,
        so - unlike every other step here - this specifically asks for a Yes/No confirmation
        before doing it (via Invoke-WPFUIThreadWithResult, since this runs in the background
        install runspace, not the UI thread) rather than treating it as an implicit side effect of
        uninstalling WSL2. Declining leaves the distro registered (orphaned once the WSL runtime
        below is gone, but not deleted) - "wsl --uninstall" doesn't require every distro to be
        gone first; it removes the WSL runtime/app regardless.

        Does not disable the underlying Windows optional features (Microsoft-Windows-Subsystem-
        Linux, VirtualMachinePlatform) - "wsl --uninstall" doesn't touch those, and turning them
        off is a separate, more disruptive step (needs a restart) that isn't done here.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    $ownedDistros = @($sync.configs.applicationsHashtable.Values | Where-Object { $_.installType -eq "wslDistro" })
    $registeredOwnedDistros = @($ownedDistros | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.distro) -and (Test-WinUtilWSLDistroInstalled -Distro $_.distro)
    })

    if ($registeredOwnedDistros.Count -gt 0) {
        $distroNames = ($registeredOwnedDistros | ForEach-Object { $_.content }) -join ", "
        $confirmed = Invoke-WPFUIThreadWithResult -ScriptBlock {
            (Show-WinUtilMessage -Message "Uninstalling WSL2 will also permanently delete the following WSL distro(s) and all data inside them:`n - $distroNames`n`nDelete them now?" -Title "Confirm WSL distro deletion" -Button ([System.Windows.MessageBoxButton]::YesNo) -Icon "Warning") -eq [System.Windows.MessageBoxResult]::Yes
        }

        if ($confirmed) {
            Uninstall-WinUtilWSLDistro -Packages $registeredOwnedDistros
        } else {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Skipping deletion of $distroNames - declined. Left registered (will become orphaned, not deleted, once the WSL2 runtime below is uninstalled)."
        }
    }

    foreach ($package in $Packages) {
        $name = $package.content
        Write-WinUtilLog -Component "Package" -Message "Uninstalling WSL2 ($name)"
        try {
            & wsl --shutdown 2>&1 | Out-Null
            $output = (& wsl --uninstall 2>&1 | Out-String).Trim()
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --uninstall completed with no console output)" })
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: this removes the WSL runtime, not the underlying Windows optional features (Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform) - turn those off separately in Windows Features if you want WSL2 fully disabled."
            # The optional features stay "Enabled" per DISM even though the runtime is now gone
            # (see above) - flag this so Test-WinUtilWSLFeatureEnabled doesn't keep reporting
            # WSL2 as usable for the rest of this app session.
            if ($null -ne $sync) { $sync.WSLRuntimeUninstalled = $true }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall WSL2: $_"
        }
    }
}
