function Find-WinUtilAppLaunchTarget {
    <#
    .SYNOPSIS
        Finds a Start Menu entry matching an app's display name, for launching apps whose
        install location isn't otherwise known.

    .DESCRIPTION
        Community-distributed installers (installType "github") run interactively so the
        user can pick options/location themselves, and winget/choco don't hand back an
        install path either - so this is the only generic way to relaunch an already-
        installed app without hardcoding a path per package.

        Uses Get-StartApps rather than scanning the Programs folder for .lnk files directly,
        since it's the one enumeration that uniformly covers both classic (.lnk-based) and
        MSIX/Store-packaged apps (which have no .lnk file at all - e.g. Windows Terminal only
        shows up here, via its AppID).

        Tries an exact (normalized) name match first, only falling back to a loose bidirectional
        substring match if nothing exact is found - a plain substring match alone is unreliable
        (e.g. app name "Firefox" would arbitrarily match either "Firefox" or the unrelated
        "Firefox Private Browsing" entry depending on enumeration order).

    .OUTPUTS
        A "shell:AppsFolder\<AppID>" path Start-Process can launch directly, or $null if no
        matching Start Menu entry was found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    function Get-NormalizedName([string]$Name) {
        $Name -replace '[^a-zA-Z0-9]', ''
    }

    $normalizedAppName = Get-NormalizedName $AppName
    if ([string]::IsNullOrWhiteSpace($normalizedAppName)) {
        return $null
    }

    $candidates = Get-StartApps | Where-Object { $_.AppID } | ForEach-Object {
        [pscustomobject]@{
            AppID = $_.AppID
            NormalizedName = Get-NormalizedName $_.Name
        }
    }

    $exactMatch = $candidates | Where-Object { $_.NormalizedName -eq $normalizedAppName } | Select-Object -First 1
    if ($exactMatch) {
        return "shell:AppsFolder\$($exactMatch.AppID)"
    }

    # Break ties by closest name length to the target instead of just taking the first match -
    # a plain "first substring match wins" would arbitrarily prefer whichever entry happens to
    # enumerate first (e.g. app name "Chrome" matching unrelated "Chrome Remote Desktop" ahead
    # of the actual "Google Chrome" entry, since both contain "Chrome").
    $looseMatch = $candidates | Where-Object {
        $_.NormalizedName -and (
            $_.NormalizedName -like "*$normalizedAppName*" -or $normalizedAppName -like "*$($_.NormalizedName)*"
        )
    } | Sort-Object { [Math]::Abs($_.NormalizedName.Length - $normalizedAppName.Length) } | Select-Object -First 1
    if ($looseMatch) {
        return "shell:AppsFolder\$($looseMatch.AppID)"
    }

    return $null
}
