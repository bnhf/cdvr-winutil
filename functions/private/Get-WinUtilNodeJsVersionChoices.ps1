function Get-WinUtilNodeJsVersionChoices {
    <#
    .SYNOPSIS
        Builds the version list for Node.js's install prompt: the latest release of each of
        the 5 most recent major versions that winget can actually install, sourced from
        winget's own catalog ("winget show --id OpenJS.NodeJS --versions") - a finite,
        "reasonable" set rather than letting the user type anything.

    .DESCRIPTION
        Deliberately sourced from winget itself, not nodejs.org's own release index (an earlier
        version of this function used that instead). Confirmed live: this is a real, reported
        install failure, not a theoretical one - winget-pkgs' Node.js manifests don't track
        every nodejs.org patch release (e.g. 24.11.0 through 24.13.0 don't exist in winget's
        catalog at all, which jumps straight from 24.10.0 to 25.0.0), so a version picked from
        nodejs.org's list can be entirely unavailable to Install-WinUtilProgramWinget's
        "--version X --exact", which then fails outright with winget's own "No version found
        matching: X" - exactly what happened. Sourcing straight from winget's catalog guarantees
        every offered choice is actually installable. The tradeoff: winget's plain version list
        carries no LTS/Current metadata the way nodejs.org's index.json does, so choices are
        shown as plain version numbers rather than labelled "(LTS: ...)"/"(Current)" - accuracy
        over cosmetics.

        A successful fetch is cached for the life of the process (module-level $script:
        variable) - this is called fresh every time the Node.js install prompt opens, and
        winget's catalog can't meaningfully change within a single WinUtil run, so there's no
        reason to re-query and make the dialog wait past the very first open. A failed fetch is
        deliberately NOT cached, so a transient issue doesn't permanently downgrade the rest of
        the session to the no-version-pinned fallback.

        If winget's catalog can't be queried at all (or returns nothing parseable), the one
        fallback choice has an empty Value, not a hardcoded version guess - Resolve-
        WinUtilPackagePrompts treats an empty PromptValues entry as "no version selected" and
        skips appending "@version" to the winget id, so the install falls back to a plain,
        unpinned "winget install --id OpenJS.NodeJS" (whatever winget itself resolves as
        latest/upgrade target) instead of risking a second hardcoded version that may equally
        not exist in the catalog.

        Must be called from the UI thread (via Resolve-WinUtilPackagePrompts, before the
        install runspace starts) - same constraint as Show-WinUtilPromptDialog itself.

    .OUTPUTS
        [pscustomobject] with .Choices (array of {Value, Label}, newest first) and .Default.
    #>
    if ($script:WinUtilNodeJsVersionChoicesCache) {
        return $script:WinUtilNodeJsVersionChoicesCache
    }

    $choices = [System.Collections.Generic.List[object]]::new()
    $fetchSucceeded = $false

    try {
        $output = & winget show --id OpenJS.NodeJS --versions --accept-source-agreements --disable-interactivity 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "winget exited with code $LASTEXITCODE"
        }

        # winget's own version list output is one bare "24.10.0"-style line per version, mixed
        # in with header/separator lines ("Found Node.js [...]", "Version", "-------") - the
        # anchored N.N.N pattern keeps only the version lines.
        $versions = @($output | Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
        if ($versions.Count -eq 0) {
            throw "no versions parsed from winget's output"
        }

        $latestByMajor = @($versions |
            Group-Object { ($_ -split '\.')[0] } |
            ForEach-Object { ($_.Group | Sort-Object { [version]$_ } -Descending | Select-Object -First 1) } |
            Sort-Object { [int](($_ -split '\.')[0]) } -Descending |
            Select-Object -First 5)

        foreach ($version in $latestByMajor) {
            $choices.Add([pscustomobject]@{ Value = $version; Label = $version })
        }
        $fetchSucceeded = $true
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Could not fetch Node.js's available versions from winget - falling back to an unpinned install: $_"
    }

    if ($choices.Count -eq 0) {
        $choices.Add([pscustomobject]@{ Value = ""; Label = "Latest available (couldn't check specific versions)" })
    }

    $choicesResult = [pscustomobject]@{
        Choices = $choices.ToArray()
        Default = $choices[0].Value
    }
    if ($fetchSucceeded) {
        $script:WinUtilNodeJsVersionChoicesCache = $choicesResult
    }
    return $choicesResult
}
