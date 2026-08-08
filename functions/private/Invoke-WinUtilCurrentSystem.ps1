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
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = ($_.Value.choco -split ";")[-1].Trim()
            if ($packageId -ne "na" -and $packageId -in $apps) {
                Write-Output $_.Key
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
            $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
                $packageId = (($_.Value.winget -split ";")[-1] -replace "^msstore:", "").Trim()
                if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                    return
                }
                if (Test-WinUtilProgramInstalled -WingetId $packageId) {
                    Write-Output $_.Key
                }
            }
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
    }

    # WSL-based entries (wslFeature/wslDistro) carry no winget/choco id at all, so they need
    # their own checks - this runs for either package-manager preference, since $CheckBox is
    # "choco" xor "winget" per call (never both), while WSL detection isn't preference-specific.
    if ($CheckBox -eq "choco" -or $CheckBox -eq "winget") {
        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            # Capture the entry before switching - inside a switch's matched-clause script
            # blocks, $_ is rebound to the switch's own subject value, shadowing the $_ from
            # this enclosing ForEach-Object.
            $entry = $_
            switch ($entry.Value.installType) {
                "wslFeature" {
                    if (Test-WinUtilWSLFeatureEnabled) { Write-Output $entry.Key }
                }
                "wslDistro" {
                    if ($entry.Value.distro -and (Test-WinUtilWSLDistroInstalled -Distro $entry.Value.distro)) {
                        Write-Output $entry.Key
                    }
                }
            }
        }
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
