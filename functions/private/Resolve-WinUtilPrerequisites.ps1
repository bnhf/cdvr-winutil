function Resolve-WinUtilPrerequisites {
    <#
    .SYNOPSIS
        For each package that declares "requires", checks whether each required catalog
        entry is already installed; if not, offers (Yes/No) to install it alongside the
        selection. If declined, the dependent package is dropped from the run.

        Must be called from the UI thread (shows a modal Yes/No dialog) - before the
        selection is handed off to the background install runspace.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$PackagesToInstall
    )

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $PackagesToInstall) { $result.Add($p) }

    $queuedKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $result) {
        if ($p.Key) { [void]$queuedKeys.Add([string]$p.Key) }
    }

    # WSL2 needs hardware virtualization (Intel VT-x / AMD-V) enabled in firmware - unlike the
    # Windows optional features it also needs, there's no "install this for you" fix since it's
    # a BIOS/UEFI setting, so this runs before the normal requires-resolution below and drops
    # WSL2 (and anything already queued that needs it: Debian, Docker Desktop, Olivetin) outright
    # rather than offering the usual Yes/No prompt. Only a definite $false blocks anything - a
    # $null result (can't be determined) is not evidence virtualization is actually unavailable.
    $needsWsl2 = @($result) | Where-Object {
        $_.installType -eq "wslFeature" -or ($_.requires -and $_.requires -contains "wsl2")
    }
    if ($needsWsl2.Count -gt 0 -and (Test-WinUtilVirtualizationFirmwareEnabled) -eq $false) {
        $names = ($needsWsl2 | ForEach-Object { $_.content }) -join ", "
        [void](Show-CustomDialog -Title "Virtualization is disabled" -Message "WSL2 requires hardware virtualization (Intel VT-x / AMD-V), which appears to be disabled in this PC's BIOS/UEFI firmware settings. Enable it there, then try again.`n`nSkipping: $names")
        Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping WSL2-dependent packages - hardware virtualization firmware appears disabled: $names"
        foreach ($p in $needsWsl2) {
            [void]$result.Remove($p)
            if ($p.Key) { [void]$queuedKeys.Remove([string]$p.Key) }
        }
    }

    $toDrop = [System.Collections.Generic.List[object]]::new()

    foreach ($package in @($result)) {
        if (-not $package.requires -or @($package.requires).Count -eq 0) { continue }

        $missing = [System.Collections.Generic.List[object]]::new()
        foreach ($reqKey in $package.requires) {
            if ($queuedKeys.Contains([string]$reqKey)) { continue }

            $reqEntry = $sync.configs.applicationsHashtable."WPFInstall$reqKey"
            if (-not $reqEntry) {
                Write-WinUtilLog -Level "WARN" -Component "Install" -Message "$($package.content) declares unknown prerequisite '$reqKey'."
                continue
            }

            $isInstalled = switch ($reqEntry.installType) {
                "wslFeature" { Test-WinUtilWSLFeatureEnabled }
                "wslDistro" { Test-WinUtilWSLDistroInstalled -Distro $reqEntry.distro }
                default { Test-WinUtilProgramInstalled -WingetId $reqEntry.winget -ChocoId $reqEntry.choco }
            }

            if (-not $isInstalled) {
                $missing.Add([pscustomobject]@{ Key = $reqKey; Entry = $reqEntry })
            }
        }

        if ($missing.Count -eq 0) { continue }

        $names = ($missing | ForEach-Object { $_.Entry.content }) -join ", "
        # Matches Invoke-WPFUnInstall.ps1's own uninstall confirmation - a real Name/Description
        # row per app instead of a plain comma-joined name list, via the same themed dialog
        # rather than a native MessageBox that looks visibly out of place appearing mid-flow
        # right next to it.
        $missingItems = $missing | Select-Object @{Name='Name'; Expression={$_.Entry.content}}, @{Name='Description'; Expression={$_.Entry.description}}
        $response = Show-CustomDialog -Title "Missing prerequisites" -Message "$($package.content) requires the following - install these now too?" -Items $missingItems -Buttons YesNo -Width 480 -Height 420 -EnableScroll $true

        if ($response -eq "Yes") {
            foreach ($m in $missing) {
                if ($queuedKeys.Contains([string]$m.Key)) { continue }
                $entryWithKey = $m.Entry | Add-Member -NotePropertyName Key -NotePropertyValue $m.Key -PassThru -Force
                $result.Add($entryWithKey)
                [void]$queuedKeys.Add([string]$m.Key)
            }
        } else {
            Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping $($package.content) - required prerequisites declined: $names"
            $toDrop.Add($package)
        }
    }

    foreach ($d in $toDrop) { [void]$result.Remove($d) }

    # WSL2, unlike the other prerequisites here, typically needs a system restart the first time
    # it's enabled before it's actually usable - installing a distro (or anything that needs a
    # working WSL2, e.g. Docker Desktop) in the very same run as enabling WSL2 for the first time
    # is likely to fail even though the WSL2 feature install itself succeeded (this is what
    # happened: WSL2 enabled fine, the immediately-following Debian install then failed). Only
    # gates when WSL2 wasn't already enabled before this run - if it's already usable, there's
    # nothing to restart for, and everything proceeds normally in one run as before.
    if (-not (Test-WinUtilWSLFeatureEnabled)) {
        $wslDependents = @($result) | Where-Object {
            $_.installType -ne "wslFeature" -and ($_.installType -eq "wslDistro" -or ($_.requires -and $_.requires -contains "wsl2"))
        }
        if ($wslDependents.Count -gt 0) {
            $names = ($wslDependents | ForEach-Object { $_.content }) -join ", "
            [void](Show-CustomDialog -Title "Restart required for WSL2" -Message "WSL2 needs a system restart before it can actually be used - installing it and then immediately installing $names in the same run is likely to fail. This run will enable WSL2 only.`n`nRestart your PC, then come back and install: $names")
            Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping WSL2-dependent packages this run - WSL2 was not already enabled and typically needs a restart first: $names"
            foreach ($p in $wslDependents) {
                [void]$result.Remove($p)
                if ($p.Key) { [void]$queuedKeys.Remove([string]$p.Key) }
            }
        }
    }

    # Packages sharing the same install bucket (e.g. Docker Desktop and Debian both installing
    # via winget) had no ordering relative to each other before this - see
    # Get-WinUtilPackagesInDependencyOrder.ps1 for the confirmed real case that prompted it.
    $orderedResult = Get-WinUtilPackagesInDependencyOrder -Packages @($result)

    # The leading comma matters: PowerShell unwraps a returned empty array to $null across the
    # function-return boundary, and $null then fails to bind to Resolve-WinUtilPackagePrompts's
    # mandatory [object[]] parameter (e.g. every selected package had a declined/blocked
    # prerequisite) - a ParameterArgumentValidationErrorNullNotAllowed exception instead of the
    # intended "nothing left to install" no-op.
    return ,$orderedResult
}
