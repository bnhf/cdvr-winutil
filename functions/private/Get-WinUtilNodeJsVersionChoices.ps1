function Get-WinUtilNodeJsVersionChoices {
    <#
    .SYNOPSIS
        Builds the version list for Node.js's install prompt: the latest release of each
        active LTS line plus the latest Current release, fetched live from nodejs.org's own
        release index - a finite, "reasonable" set rather than letting the user type anything.

    .DESCRIPTION
        v24.13.0 (WinUtil's own chosen default) is always present in the returned choices and
        is always the default, even if nodejs.org can't be reached or that exact version isn't
        (yet, or no longer) in the live index - the prompt must never come up empty just because
        the fetch failed, and must never silently default the user to a version WinUtil hasn't
        picked.

        Must be called from the UI thread (via Resolve-WinUtilPackagePrompts, before the
        install runspace starts) - same constraint as Show-WinUtilPromptDialog itself.

    .OUTPUTS
        [pscustomobject] with .Choices (array of {Value, Label}, newest first) and .Default
        (string, always "24.13.0").
    #>
    $default = "24.13.0"
    $choices = [System.Collections.Generic.List[object]]::new()

    try {
        $index = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -TimeoutSec 10

        # nodejs.org returns releases newest-first, so the first entry is the current release
        # regardless of LTS status.
        $current = $index | Select-Object -First 1

        $ltsLatestByMajor = @($index | Where-Object { $_.lts -and $_.lts -ne $false } |
            Group-Object { ($_.version.TrimStart('v') -split '\.')[0] } |
            ForEach-Object { $_.Group | Sort-Object { [version]($_.version.TrimStart('v')) } -Descending | Select-Object -First 1 })
        $ltsLatestByMajor = @($ltsLatestByMajor | Sort-Object { [version]($_.version.TrimStart('v')) } -Descending)

        if ($current -and (-not $current.lts -or $current.lts -eq $false)) {
            $currentVersion = $current.version.TrimStart('v')
            $choices.Add([pscustomobject]@{ Value = $currentVersion; Label = "$currentVersion (Current)" })
        }

        foreach ($release in $ltsLatestByMajor) {
            $version = $release.version.TrimStart('v')
            $choices.Add([pscustomobject]@{ Value = $version; Label = "$version (LTS: $($release.lts))" })
        }
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Could not fetch the Node.js version list from nodejs.org - falling back to the default version only: $_"
    }

    if (-not ($choices | Where-Object { $_.Value -eq $default })) {
        $choices.Insert(0, [pscustomobject]@{ Value = $default; Label = "$default (default)" })
    }

    return [pscustomobject]@{
        Choices = $choices.ToArray()
        Default = $default
    }
}
