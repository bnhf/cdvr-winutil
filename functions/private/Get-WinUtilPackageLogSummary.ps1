function Get-WinUtilPackageLogSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$Preference
    )

    @($Packages | ForEach-Object {
        $package = $_
        # "content" is the catalog's actual display-name field (config/applications.json has no
        # "Name" property on any entry) - confirmed live: with "Name" checked first and falling
        # through to "Description" once that's never found, every install/uninstall summary line
        # showed the app's full description instead of its name (e.g. "Native Win32 client for
        # Channels DVR written in Rust with WinUI3 styling, by mackid1993..." instead of
        # "Clicker"), for every app, not just ones missing a winget/choco id.
        $packageName = @($package.content, $package.Name, $package.Description, $package.winget, $package.choco) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -ne "na" } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace([string]$packageName)) {
            $packageName = "Unknown package"
        }

        if ($Preference -eq "Choco" -and -not [string]::IsNullOrWhiteSpace([string]$package.choco) -and $package.choco -ne "na") {
            "$packageName (choco: $($package.choco))"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$package.winget) -and $package.winget -ne "na") {
            "$packageName (winget: $($package.winget))"
        } else {
            "$packageName (no package id)"
        }
    })
}
