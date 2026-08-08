Function Uninstall-WinUtilWSLDistro {
    <#
    .SYNOPSIS
        Unregisters a WSL distro (e.g. Debian) - this permanently deletes its filesystem and
        all data inside it, not just "removes" it. Only ever call this for distros WinUtil's
        own catalog installed - never for an arbitrary/unknown distro, since that data isn't
        ours to delete.

    .DESCRIPTION
        Bounded via Invoke-WinUtilWithTimeout, not the few-second default used elsewhere for
        quick DISM/registry checks - deleting a distro's filesystem can take a little while, and
        wsl.exe itself can occasionally hang for unrelated reasons (see
        Install-WinUtilWSLDistro.ps1 for a confirmed real case on the install side; unregister
        isn't known to hit the same interactive first-run prompt, but there's no reason to trust
        it unconditionally either). Verifies success afterward via Test-WinUtilWSLDistroInstalled
        rather than trusting wsl.exe's own exit behavior, for the same reason a timeout here
        isn't necessarily a real failure.
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

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 120 -DefaultValue $null -ArgumentList @($distro) -ScriptBlock {
            param($distro)
            try {
                & wsl --terminate $distro 2>&1 | Out-Null
                return (& wsl --unregister $distro 2>&1 | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --unregister $distro did not finish within the expected time - checking whether it actually unregistered anyway."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --unregister $distro completed with no console output)" })
        }

        if (Test-WinUtilWSLDistroInstalled -Distro $distro) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$name ($distro) still appears registered after the unregister attempt."
        } else {
            Write-WinUtilLog -Component "Package" -Message "$name ($distro) is unregistered."
        }
    }
}
