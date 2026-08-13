function Stop-WinUtilProcessByAssetPattern {
    <#
    .SYNOPSIS
        Force-stops any running process (and its child processes) whose image name matches a
        catalog assetPattern - e.g. "PlutoForChannels*.exe" - used by portable github-install-type
        packages before overwriting or deleting their files.

    .DESCRIPTION
        Uses taskkill's /FI IMAGENAME filter, not /IM directly, and not Get-Process/Stop-Process.
        Both of those were tried first and both silently failed to actually find/stop Pluto for
        Channels' running process across three separate live reports of the same underlying
        symptom (uninstall reporting incomplete, or a reinstall failing to replace a locked
        file) before the real cause was pinned down:

        - Get-Process matched by install-folder Path, then by Path-or-Name, both missed the
          actual running process - its Path/Name properties depend on reading another process's
          MainModule info, which can silently fail across the integrity-level boundary between
          WinUtil's own elevated process and this app's de-elevated one.
        - "taskkill /F /IM PlutoForChannels*.exe" - the obvious next fix - was then confirmed
          empirically (against a real running process, not just documentation) to not actually
          work at all: /IM does NOT support wildcards despite being commonly described as if it
          did. It matched nothing and killed nothing, every single time, silently reporting
          "ERROR: The process ... not found" - explaining why the exact same symptom kept
          resurfacing even after that "fix" shipped.

        The actual working mechanism, also confirmed empirically: taskkill's /FI IMAGENAME
        filter DOES support a wildcard, but only a single trailing one with nothing after it -
        "IMAGENAME eq cm*" correctly matched and killed a running cmd.exe-based process, while
        "IMAGENAME eq cm*.exe" failed outright with "ERROR: The search filter cannot be
        recognized" (the wildcard followed by a literal suffix isn't valid filter syntax at
        all). Catalog assetPatterns are shaped like "<Name>*.exe" - wildcard, then a literal
        suffix - so this strips everything from the first "*" onward, KEEPING the "*", turning
        "PlutoForChannels*.exe" into "PlutoForChannels*" before building the filter.

        taskkill operates purely on the OS process table by image name and terminates
        synchronously, without needing to read the target process's own module info at all -
        unlike the Get-Process approaches above, nothing about it depends on the caller's and
        target's relative integrity levels. /T also terminates any child processes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetPattern
    )

    $wildcardIndex = $AssetPattern.IndexOf('*')
    $filterPattern = if ($wildcardIndex -ge 0) { $AssetPattern.Substring(0, $wildcardIndex + 1) } else { $AssetPattern }

    & taskkill /F /FI "IMAGENAME eq $filterPattern" /T 2>$null | Out-Null
}
