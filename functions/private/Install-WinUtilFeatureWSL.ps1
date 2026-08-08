Function Install-WinUtilFeatureWSL {
    <#
    .SYNOPSIS
        Enables the WSL2 platform feature. First-time enable on many systems requires a
        reboot before WSL is actually usable - this does not claim silent one-click success.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        Write-WinUtilLog -Component "Package" -Message "Enabling WSL2 ($name)"
        try {
            $output = (& wsl --install --no-distribution 2>&1 | Out-String).Trim()
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --install completed with no console output)" })
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: if this is the first time WSL has been enabled on this machine, a restart may be required before it is usable."
            # Clears the "uninstalled this session" flag Uninstall-WinUtilFeatureWSL sets, so
            # Test-WinUtilWSLFeatureEnabled goes back to trusting the real DISM/optional-feature
            # state now that WSL2 has been (re)installed.
            if ($null -ne $sync) { $sync.WSLRuntimeUninstalled = $false }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to enable WSL: $_"
        }
    }
}
