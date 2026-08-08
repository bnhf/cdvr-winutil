Function Install-WinUtilWSLDistro {
    <#
    .SYNOPSIS
        Installs a WSL distro (e.g. Debian). Requires the WSL2 feature to already be enabled.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $distro = $package.distro

        if ([string]::IsNullOrWhiteSpace($distro)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "WSL distro install for $name is missing distro."
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing WSL distro $distro ($name)"
        try {
            $output = (& wsl --install -d $distro 2>&1 | Out-String).Trim()
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --install -d $distro completed with no console output)" })
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to install WSL distro ${distro}: $_"
        }
    }
}
