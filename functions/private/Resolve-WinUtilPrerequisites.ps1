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
        [object[]]$PackagesToInstall
    )

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $PackagesToInstall) { $result.Add($p) }

    $queuedKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $result) {
        if ($p.Key) { [void]$queuedKeys.Add([string]$p.Key) }
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
        $response = Show-WinUtilMessage -Message "$($package.content) requires: $names`n`nInstall these now too?" -Title "Missing prerequisites" -Button ([System.Windows.MessageBoxButton]::YesNo) -Icon "Question"

        if ($response -eq [System.Windows.MessageBoxResult]::Yes) {
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

    return $result.ToArray()
}
