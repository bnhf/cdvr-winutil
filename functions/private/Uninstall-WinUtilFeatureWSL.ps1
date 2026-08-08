Function Uninstall-WinUtilFeatureWSL {
    <#
    .SYNOPSIS
        Uninstalls the WSL2 platform: stops any running distros, unregisters the distro(s)
        WinUtil's own catalog manages (e.g. Debian), then runs "wsl --uninstall".

    .DESCRIPTION
        Only unregisters distros declared in WinUtil's own catalog (installType "wslDistro") -
        never anything else that might be registered on this machine, since that data isn't
        ours to delete. "wsl --uninstall" itself doesn't require every distro to be gone first;
        it removes the WSL runtime/app regardless, and any distro left registered (e.g. one the
        user set up themselves, outside WinUtil) is left orphaned - not usable via wsl until the
        runtime is reinstalled, but not deleted either.

        Does not disable the underlying Windows optional features (Microsoft-Windows-Subsystem-
        Linux, VirtualMachinePlatform) - "wsl --uninstall" doesn't touch those, and turning them
        off is a separate, more disruptive step (needs a restart) that isn't done here.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    $ownedDistros = @($sync.configs.applicationsHashtable.Values | Where-Object { $_.installType -eq "wslDistro" })
    if ($ownedDistros.Count -gt 0) {
        Uninstall-WinUtilWSLDistro -Packages $ownedDistros
    }

    foreach ($package in $Packages) {
        $name = $package.content
        Write-WinUtilLog -Component "Package" -Message "Uninstalling WSL2 ($name)"
        try {
            & wsl --shutdown 2>&1 | Out-Null
            $output = & wsl --uninstall 2>&1 | Out-String
            Write-WinUtilLog -Component "Package" -Message $output.Trim()
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: this removes the WSL runtime, not the underlying Windows optional features (Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform) - turn those off separately in Windows Features if you want WSL2 fully disabled."
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall WSL2: $_"
        }
    }
}
