function Get-WinUtilNodeJsVersionChoices {
    <#
    .SYNOPSIS
        Builds the version list for Node.js's install prompt: the latest release of each of
        the 5 most recent major versions (Current plus however many of those are still LTS),
        fetched live from nodejs.org's own release index - a finite, "reasonable" set rather
        than letting the user type anything.

    .DESCRIPTION
        v24.13.0 (WinUtil's own chosen default) is always present in the returned choices and
        is always the default, even if nodejs.org can't be reached or that exact version isn't
        (yet, or no longer) in the live index - the prompt must never come up empty just because
        the fetch failed, and must never silently default the user to a version WinUtil hasn't
        picked.

        Deliberately sourced from nodejs.org, NOT winget - a previous version of this function
        tried sourcing from winget's own catalog instead ("winget show --id OpenJS.NodeJS
        --versions"), reasoning that would guarantee every offered choice installs cleanly. That
        broke worse: confirmed live, winget doesn't publish Node.js as one package with full
        history - it's split across OpenJS.NodeJS (only the newest ~3 majors, pruned as they
        age), OpenJS.NodeJS.LTS (ONLY the current Active LTS major, e.g. just 24.x today), and a
        separate OpenJS.NodeJS.<N> per older major once it ages out of the main package. No
        single id ever covers 5 majors, and the exact id needed for a given version (e.g.
        24.13.0, which lives in OpenJS.NodeJS.LTS but not OpenJS.NodeJS) varies per version -
        pinning against one static id could only ever install a fraction of what was offered.
        nodejs.org's own release archive, by contrast, keeps every version forever at a
        predictable URL - see Install-WinUtilProgramDirect's "command"/url handling and this
        package's "url"/"versionPrompt" fields in config/applications.json, which install the
        chosen version by downloading its MSI directly from nodejs.org rather than through
        winget at all. That sidesteps winget's catalog fragmentation entirely, so this function
        is free to offer whatever's actually the 5 most recent major releases.

        A successful fetch is cached for the life of the process (module-level $script:
        variable) - this is called fresh every time the Node.js install prompt opens, and
        nodejs.org's release list can't meaningfully change within a single WinUtil run, so
        there's no reason to re-fetch and make the dialog wait on the network past the very
        first open. A failed fetch is deliberately NOT cached, so a transient outage doesn't
        permanently downgrade the rest of the session to the single-choice fallback.

        Must be called from the UI thread (via Resolve-WinUtilPackagePrompts, before the
        install runspace starts) - same constraint as Show-WinUtilPromptDialog itself.

    .OUTPUTS
        [pscustomobject] with .Choices (array of {Value, Label}, newest first) and .Default
        (string, always "24.13.0").
    #>
    if ($script:WinUtilNodeJsVersionChoicesCache) {
        return $script:WinUtilNodeJsVersionChoicesCache
    }

    $default = "24.13.0"
    $choices = [System.Collections.Generic.List[object]]::new()
    $fetchSucceeded = $false

    try {
        # A short timeout matters here specifically because this call blocks the UI thread -
        # Resolve-WinUtilPackagePrompts needs the choices before it can even show the dialog,
        # so a slow/unresponsive nodejs.org would otherwise make the whole prompt hang rather
        # than just falling back quickly to the one guaranteed default choice below.
        $index = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -TimeoutSec 4

        # nodejs.org returns releases newest-first, so grouping by major and taking each
        # group's first entry gives each major's latest release without an extra sort.
        $latestByMajor = @($index |
            Group-Object { ($_.version.TrimStart('v') -split '\.')[0] } |
            ForEach-Object { $_.Group[0] } |
            Sort-Object { [int]($_.version.TrimStart('v') -split '\.')[0] } -Descending |
            Select-Object -First 5)

        foreach ($release in $latestByMajor) {
            $version = $release.version.TrimStart('v')
            $label = if ($release.lts -and $release.lts -ne $false) { "$version (LTS: $($release.lts))" } else { "$version (Current)" }
            $choices.Add([pscustomobject]@{ Value = $version; Label = $label })
        }
        $fetchSucceeded = $true
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Could not fetch the Node.js version list from nodejs.org - falling back to the default version only: $_"
    }

    if (-not ($choices | Where-Object { $_.Value -eq $default })) {
        $choices.Insert(0, [pscustomobject]@{ Value = $default; Label = "$default (default)" })
    }

    $choicesResult = [pscustomobject]@{
        Choices = $choices.ToArray()
        Default = $default
    }
    if ($fetchSucceeded) {
        $script:WinUtilNodeJsVersionChoicesCache = $choicesResult
    }
    return $choicesResult
}
