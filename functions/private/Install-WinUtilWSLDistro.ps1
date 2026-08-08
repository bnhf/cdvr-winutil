Function Install-WinUtilWSLDistro {
    <#
    .SYNOPSIS
        Installs a WSL distro (e.g. Debian). Requires the WSL2 feature to already be enabled.

    .DESCRIPTION
        Bounded to several minutes via Invoke-WinUtilWithTimeout, not the few-second default
        used elsewhere for quick DISM/registry checks - downloading and registering a distro's
        filesystem image genuinely takes a while, and "wsl --install -d <distro>" can hang well
        beyond that: it normally auto-launches the distro afterward for first-run setup (create
        a UNIX username/password), an interactive prompt with no console attached in this app's
        background install runspace. Confirmed live: the distro had already finished
        registering (showed up in "wsl --list") while the install call itself never returned,
        leaving the app looking stalled with no further progress or log output.

        Verifies success afterward via Test-WinUtilWSLDistroInstalled rather than trusting
        wsl.exe's own exit behavior, for the same reason - a timeout here isn't necessarily a
        real failure, the distro may already be fully registered underneath it.
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

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 300 -DefaultValue $null -ArgumentList @($distro) -ScriptBlock {
            param($distro)
            try {
                return (& wsl --install -d $distro 2>&1 | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --install -d $distro did not finish within the expected time - checking whether it actually registered anyway (this is normal if it's waiting on the first-run username prompt, which can't be answered here)."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --install -d $distro completed with no console output)" })
        }

        if (Test-WinUtilWSLDistroInstalled -Distro $distro) {
            Write-WinUtilLog -Component "Package" -Message "$name ($distro) is installed and registered. If this was its first install, open a terminal and run `"wsl -d $distro`" once to finish creating its Linux user account."
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$name ($distro) does not appear to be registered after the install attempt."
        }
    }
}
