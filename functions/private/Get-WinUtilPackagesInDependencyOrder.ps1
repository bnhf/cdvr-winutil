function Get-WinUtilPackagesInDependencyOrder {
    <#
    .SYNOPSIS
        Reorders packages so anything another selected package "requires" installs first.

    .DESCRIPTION
        Invoke-WPFInstall.ps1 already runs the WSL2-feature/distro buckets before winget/choco
        as a whole, but packages sharing the SAME bucket (e.g. Docker Desktop and Debian both
        installing via winget now that Debian moved off "wsl --install") had no ordering between
        them - confirmed live: Docker Desktop installed before Debian despite declaring "debian"
        as a requirement, which happened to be harmless this time (Docker Desktop's own install
        doesn't actually need Debian present, only Olivetin - which runs inside Debian - does),
        but is exactly the kind of ordering an actual dependency could break on.

        A topological sort by .Key/.requires, not a hardcoded pairwise check - the catalog
        already has multi-level chains (wsl2 -> debian -> dockerdesktop -> olivetin), and a
        general sort handles any current or future one correctly without needing to special-case
        each pair. Packages without a .Key can't participate in the requires graph (nothing can
        reference them, and their own "requires" can't be resolved against .Key), so they always
        qualify immediately.

        Implemented as repeated passes over the remaining packages (emit anything whose
        in-selection requirements are already placed, repeat until nothing changes), rather than
        recursive-descent through a nested helper function - functionally equivalent, but reads
        more directly as "keep placing whatever's ready" without needing a second function to
        follow. Bounded to at most Packages.Count passes - a dependency cycle (should never
        happen from the catalog itself, but a defensive guard for it regardless) stops making
        progress and whatever's left just gets appended in its original order rather than
        looping forever.

        Returns ,$sorted.ToArray() (leading comma) rather than $sorted.ToArray() - the usual
        reason (PowerShell unwraps a returned empty array to $null across a function-return
        boundary otherwise) plus a corollary worth knowing at every call site: a caller that
        wraps the CALL ITSELF in @(...) - e.g. @(Get-WinUtilPackagesInDependencyOrder ...).Count
        - double-wraps the result, since the comma already makes the array a single pipeline
        object and @() around the call adds another layer. Capture the result in a variable
        first ($result = Get-WinUtilPackagesInDependencyOrder ...), then wrap or measure that
        variable - @() around an already-materialized array variable is idempotent, only @()
        around the call itself is not.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Packages
    )

    $byKey = @{}
    foreach ($p in $Packages) {
        if ($p.Key) { $byKey[[string]$p.Key] = $p }
    }

    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Packages) { $remaining.Add($p) }

    $sorted = [System.Collections.Generic.List[object]]::new()
    $placedKeys = [System.Collections.Generic.HashSet[string]]::new()

    $maxPasses = $remaining.Count
    for ($pass = 0; $pass -lt $maxPasses -and $remaining.Count -gt 0; $pass++) {
        $placedThisPass = [System.Collections.Generic.List[object]]::new()

        foreach ($package in @($remaining)) {
            $unmetRequirement = $false
            foreach ($reqKey in @($package.requires)) {
                $reqKeyString = [string]$reqKey
                if ($byKey.ContainsKey($reqKeyString) -and -not $placedKeys.Contains($reqKeyString)) {
                    $unmetRequirement = $true
                    break
                }
            }

            if (-not $unmetRequirement) {
                $sorted.Add($package)
                if ($package.Key) { [void]$placedKeys.Add([string]$package.Key) }
                $placedThisPass.Add($package)
            }
        }

        if ($placedThisPass.Count -eq 0) { break }
        foreach ($p in $placedThisPass) { [void]$remaining.Remove($p) }
    }

    # Only reached on a genuine dependency cycle - append what's left rather than drop it.
    foreach ($p in $remaining) { $sorted.Add($p) }

    return ,$sorted.ToArray()
}
