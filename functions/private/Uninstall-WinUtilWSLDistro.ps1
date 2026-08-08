Function Uninstall-WinUtilWSLDistro {
    <#
    .SYNOPSIS
        Unregisters a WSL distro (e.g. Debian) - this permanently deletes its filesystem and
        all data inside it, not just "removes" it. Only ever call this for distros WinUtil's
        own catalog installed - never for an arbitrary/unknown distro, since that data isn't
        ours to delete.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $distro = $package.distro

        if ([string]::IsNullOrWhiteSpace($distro)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "WSL distro uninstall for $name is missing distro."
            continue
        }

        if (-not (Test-WinUtilWSLDistroInstalled -Distro $distro)) {
            Write-WinUtilLog -Component "Package" -Message "$name ($distro) is not registered - nothing to uninstall."
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Unregistering WSL distro $distro ($name) - this deletes its filesystem and data."
        try {
            & wsl --terminate $distro 2>&1 | Out-Null
            $output = & wsl --unregister $distro 2>&1 | Out-String
            Write-WinUtilLog -Component "Package" -Message $output.Trim()
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to unregister WSL distro ${distro}: $_"
        }
    }
}
