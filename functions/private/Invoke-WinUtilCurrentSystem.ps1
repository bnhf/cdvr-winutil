Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    # "Show Installed Apps" (checkbox "choco"/"winget") calls winget/choco once per app, which
    # is slow enough to be noticeable with no feedback - report per-app progress on the same
    # window-level indicator the install/uninstall workflows use, so it reads the same way.
    if ($CheckBox -eq "choco" -or $checkbox -eq "winget") {
        $appsToCheck = @($sync.configs.applicationsHashtable.GetEnumerator())
        $totalToCheck = $appsToCheck.Count
        $checkedCount = 0
        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Checking installed apps (0/$totalToCheck)" -Percent 0
    }

    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        foreach ($entry in $appsToCheck) {
            $checkedCount++
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Checking $($entry.Value.content) ($checkedCount/$totalToCheck)" -Percent ([int](($checkedCount / $totalToCheck) * 100))
            $packageId = ($entry.Value.choco -split ";")[-1].Trim()
            if ($packageId -ne "na" -and $packageId -in $apps) {
                Write-Output $entry.Key
            }
        }
    }

    if ($checkbox -eq "winget") {
        $originalEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

            # Cheap upfront sanity check so a broken winget (missing, corrupted sources, ...)
            # fails loudly here instead of silently, since the per-app lookups below each
            # swallow their own errors (Test-WinUtilProgramInstalled returns $false on any
            # failure) and would otherwise just look like "nothing is installed".
            $null = winget list --count 1 --accept-source-agreements --disable-interactivity 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "winget list failed with exit code $LASTEXITCODE."
            }

            # Per-app targeted "winget list --id <id> --exact" lookups instead of one bulk
            # "winget list" scanned with a regex: the bulk listing's Id/Source columns are
            # unreliable for apps that self-update outside of winget (e.g. Firefox showed up
            # only as an ARP registry key, with no "Mozilla.Firefox" id/source at all, even
            # though a targeted --id --exact lookup for it resolves correctly).
            foreach ($entry in $appsToCheck) {
                $checkedCount++
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Checking $($entry.Value.content) ($checkedCount/$totalToCheck)" -Percent ([int](($checkedCount / $totalToCheck) * 100))
                $packageId = (($entry.Value.winget -split ";")[-1] -replace "^msstore:", "").Trim()
                if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                    continue
                }
                if (Test-WinUtilProgramInstalled -WingetId $packageId) {
                    Write-Output $entry.Key
                }
            }
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
    }

    # WSL-based entries (wslFeature/wslDistro/wslCommand) and "direct"/"github" entries (real
    # installers with no winget/choco id at all, e.g. Channels DVR, Clicker) all need their own
    # checks - this runs for either package-manager preference, since $CheckBox is "choco" xor
    # "winget" per call (never both), while none of this is preference-specific.
    if ($CheckBox -eq "choco" -or $CheckBox -eq "winget") {
        foreach ($entry in $appsToCheck) {
            switch ($entry.Value.installType) {
                "wslFeature" {
                    if (Test-WinUtilWSLFeatureEnabled) { Write-Output $entry.Key }
                }
                "wslDistro" {
                    if ($entry.Value.distro -and (Test-WinUtilWSLDistroInstalled -Distro $entry.Value.distro)) {
                        Write-Output $entry.Key
                    }
                }
                "wslCommand" {
                    if ($entry.Value.distro -and $entry.Value.installCheckCommand -and
                        (Test-WinUtilWSLCommandInstalled -Distro $entry.Value.distro -InstallCheckCommand $entry.Value.installCheckCommand)) {
                        Write-Output $entry.Key
                    }
                }
                { $_ -eq "direct" -or $_ -eq "github" } {
                    # No winget/choco/WSL-based signal exists for these. Two independent checks,
                    # either one is enough: the catalog's own "webui" URL (already used for the
                    # app's "Open" button) when declared, and - confirmed live for Clicker via
                    # its own repo docs ("the installer registers an uninstaller") - a matching
                    # entry in Windows' Add/Remove Programs registry, the same lookup
                    # Uninstall-WinUtilProgramGithub already relies on to actually uninstall
                    # these. Regression guard: this used to be webui-only, so any github-type
                    # entry without one (4 of the 6 currently in the catalog, including Clicker)
                    # could never be detected as installed no matter what was actually on disk.
                    $reachableViaWebui = $entry.Value.webui -and (Test-WinUtilWebUIReachable -Url $entry.Value.webui)
                    $foundInAddRemovePrograms = -not [string]::IsNullOrWhiteSpace(
                        (Get-WinUtilProgramUninstallString -DisplayNamePattern "*$($entry.Value.content)*").UninstallString
                    )
                    # "portable" github-type packages (e.g. Pluto for Channels) never register in
                    # Add/Remove Programs at all - confirmed live, this caused a false negative
                    # here (and a failed uninstall attempt) even with the app fully installed and
                    # just not currently running. A third, independent signal for these: check
                    # their own fixed install folder directly, the same idea streamLinkManager
                    # uses below.
                    $foundAsPortableInstall = $entry.Value.portable -and $entry.Value.assetPattern -and
                        (Test-WinUtilPortableGithubInstalled -Name $entry.Value.content -AssetPattern $entry.Value.assetPattern)
                    if ($reachableViaWebui -or $foundInAddRemovePrograms -or $foundAsPortableInstall) {
                        Write-Output $entry.Key
                    }
                }
                "npm" {
                    # Regression guard: this installType had no detection case at all - Prismcast
                    # (currently the only npm-type entry) could never be shown as installed by
                    # "Show Installed Apps", the same class of gap "direct"/"github" had.
                    if ($entry.Value.npmPackage -and (Test-WinUtilNpmPackageInstalled -NpmPackage $entry.Value.npmPackage)) {
                        Write-Output $entry.Key
                    }
                }
                "streamLinkManager" {
                    # Install-WinUtilStreamLinkManager.ps1 always installs to this exact fixed
                    # location (it owns the whole directory, not something the user chooses) -
                    # checking the file directly is more reliable than probing "webui", which
                    # only proves the app is currently running, not that it's installed.
                    if (Test-Path (Join-Path $env:LocalAppData "StreamLinkManager\slm.exe")) {
                        Write-Output $entry.Key
                    }
                }
            }
        }
        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Finished checking installed apps" -Percent 100
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}
