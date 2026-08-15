function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [PSObject[]]$PackagesToInstall = $($sync.selectedApps | Foreach-Object {
            $pkg = $sync.configs.applicationsHashtable.$_
            if ($pkg) { $pkg | Add-Member -NotePropertyName Key -NotePropertyValue ($_ -replace '^WPFInstall', '') -PassThru -Force }
        })
    )


    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade."
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    # Shown before anything else runs, not just once the background runspace starts below -
    # confirmed live: prerequisite/prompt resolution just below can itself take a moment (modal
    # dialogs, checking whether something's already installed), during which nothing was visible
    # at all before this - a click that appeared to do nothing until the bar suddenly showed up
    # already blank.
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing install..." -Percent 0

    # Prerequisite checks and value prompts show modal dialogs, so they must run here on the
    # UI thread - before the selection is handed off to the background install runspace.
    $PackagesToInstall = Resolve-WinUtilPrerequisites -PackagesToInstall $PackagesToInstall

    # Everything can legitimately end up dropped here (e.g. a declined or blocked prerequisite),
    # so check before the next step rather than after - Resolve-WinUtilPackagePrompts still
    # requires a non-empty array by design, since it isn't meant to be called with nothing to do.
    if ($PackagesToInstall.Count -eq 0) {
        Write-WinUtilLog -Component "Install" -Message "Nothing left to install after prerequisite resolution."
        return
    }

    $PackagesToInstall = Resolve-WinUtilPackagePrompts -PackagesToInstall $PackagesToInstall

    if ($PackagesToInstall.Count -eq 0) {
        Write-WinUtilLog -Component "Install" -Message "Nothing left to install after prompt resolution."
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Install" -Message "Install requested for $(@($PackagesToInstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToInstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Install" -Message "Install selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $packagesDirect = $packagesSorted['Direct']
        $packagesGithub = $packagesSorted['Github']
        $packagesNpm = $packagesSorted['Npm']
        $packagesWslFeature = $packagesSorted['WslFeature']
        $packagesWslDistro = $packagesSorted['WslDistro']
        $packagesWslCommand = $packagesSorted['WslCommand']
        $packagesStreamLinkManager = $packagesSorted['StreamLinkManager']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count + @($packagesDirect).Count + @($packagesGithub).Count + @($packagesNpm).Count + @($packagesWslFeature).Count + @($packagesWslDistro).Count + @($packagesWslCommand).Count + @($packagesStreamLinkManager).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        # winget/choco IDs actually installed/uninstalled don't carry the friendly display name -
        # this maps back to it (falling back to the raw ID) for the failure summary below.
        $packageNameById = @{}
        # Same idea, for winget/choco packages that declare a postInstallCommand (e.g. launching
        # an app once so its first-run setup starts right away) - Install-WinUtilProgramWinget/
        # Install-WinUtilProgramChoco only deal in bare ID strings, not full package objects, so
        # this is how the install loops below find the command to run after a given ID installs
        # successfully. A package could be keyed under either ID depending on which manager
        # preference actually installed it (e.g. Docker Desktop declares both), so both get
        # indexed regardless of $ManagerPreference.
        $postInstallCommandById = @{}
        foreach ($p in $PackagesToInstall) {
            if ($p.winget -and $p.winget -ne "na") { $packageNameById[$p.winget -replace '^msstore:', ''] = $p.content }
            if ($p.choco -and $p.choco -ne "na") { $packageNameById[$p.choco] = $p.content }
            if (-not [string]::IsNullOrWhiteSpace($p.postInstallCommand)) {
                if ($p.winget -and $p.winget -ne "na") { $postInstallCommandById[$p.winget -replace '^msstore:', ''] = $p.postInstallCommand }
                if ($p.choco -and $p.choco -ne "na") { $postInstallCommandById[$p.choco] = $p.postInstallCommand }
            }
        }
        $failedPackages = [System.Collections.Generic.List[string]]::new()
        Write-WinUtilLog -Component "Install" -Message "Install package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count), direct=$(@($packagesDirect).Count), github=$(@($packagesGithub).Count), npm=$(@($packagesNpm).Count), wslFeature=$(@($packagesWslFeature).Count), wslDistro=$(@($packagesWslDistro).Count), wslCommand=$(@($packagesWslCommand).Count), streamLinkManager=$(@($packagesStreamLinkManager).Count)"

        # How many times a given installer function calls -ProgressCallback for one package -
        # New-WinUtilStepProgressCallback divides that package's percent slot evenly across this
        # many steps, so the bar actually advances as each milestone fires instead of sitting at
        # its starting value until the whole package finishes (confirmed live: labels were
        # updating correctly, but Percent only ever moved at package boundaries - a multi-step
        # single-package install, e.g. Streaming Library Manager, looked exactly like the
        # original "frozen bar" bug this was meant to fix). Must match each function's own call
        # count exactly to line up cleanly - see New-WinUtilStepProgressCallback's docstring for
        # what happens when it doesn't (harmless, just less precise).
        # WslFeature/WslDistro/WslCommand can call back repeatedly (an initial "Running..."
        # message, then again every OnWaitingIntervalSeconds while a long operation is still in
        # progress) - a higher count here means the bar keeps creeping forward through several
        # of those pings instead of reaching this package's end percent on the very first one
        # and just holding there (harmless either way, see New-WinUtilStepProgressCallback's
        # docstring, but capping too early looks the same as not advancing at all).
        $expectedProgressSteps = @{
            WslFeature = 6; WslDistro = 6; WslCommand = 6
            Direct = 2; Github = 3; Npm = 1; StreamLinkManager = 5
            Choco = 1
        }

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            # WSL2/Debian go first, ahead of winget/choco - Docker Desktop (winget) requires
            # WSL2, and previously ran before it was even enabled, since winget/choco installed
            # unconditionally first and the WSL feature/distro buckets only ran afterward as
            # part of the general bucket loop below.
            foreach ($installBucket in @(
                @{ Packages = $packagesWslFeature; StepsKey = "WslFeature"; Installer = { param($pkgs, $cb) Install-WinUtilFeatureWSL -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesWslDistro; StepsKey = "WslDistro"; Installer = { param($pkgs, $cb) Install-WinUtilWSLDistro -Packages $pkgs -ProgressCallback $cb } }
            )) {
                # @($null).Count is 1, not 0 - filtering out falsy entries first means a null or
                # missing bucket is correctly treated as empty here, instead of falling through
                # to the installer call below with $null and crashing on its Mandatory
                # [object[]] parameter ("Cannot bind argument ... because it is null").
                $bucketPackages = @($installBucket.Packages | Where-Object { $_ })

                # One package at a time, not the whole bucket in a single call - each installer
                # (via -ProgressCallback above) already reports its own milestones, but a bucket
                # with more than one package still needs its OWN per-package percent movement,
                # the same granularity the winget loop below already has.
                foreach ($pkg in $bucketPackages) {
                    $pkgName = $pkg.content
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $pkgName ($position/$totalPackages)" -Percent $startPercent
                    }

                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    # $stepCallback is a plain (non-closure) inline scriptblock, not returned
                    # from a helper - see New-WinUtilStepProgressCallback's own docstring for why
                    # that matters (a GetNewClosure'd scriptblock calling
                    # Set-WinUtilTweaksProgressIndicator by name broke under Pester).
                    $stepCallback = if ($hasUI) {
                        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent $startPercent -EndPercent $completedPercent -ExpectedSteps $expectedProgressSteps[$installBucket.StepsKey]
                        { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextStepPercent)) }
                    } else {
                        $null
                    }

                    & $installBucket.Installer @($pkg) $stepCallback

                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $pkgName ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }

            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Install-WinUtilWinget
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    $installResults = Install-WinUtilProgramWinget -Action Install -Programs @($program)
                    foreach ($r in $installResults) {
                        if (-not $r.Success) {
                            $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                        } elseif ($postInstallCommandById.ContainsKey($r.Program)) {
                            $postInstallName = if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }
                            Write-WinUtilLog -Component "Install" -Message "Running post-install step for $postInstallName`: $($postInstallCommandById[$r.Program])"
                            try {
                                & ([scriptblock]::Create($postInstallCommandById[$r.Program]))
                                Write-WinUtilLog -Component "Install" -Message "$postInstallName post-install step completed"
                            } catch {
                                Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Post-install step failed for ${postInstallName}: $_"
                            }
                        }
                    }
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                $chocoEndPercent = [int]((($completedPackages + @($packagesChoco).Count) / $totalPackages) * 100)
                $chocoStepCallback = if ($hasUI) {
                    $nextChocoStepPercent = New-WinUtilStepProgressCallback -StartPercent $startPercent -EndPercent $chocoEndPercent -ExpectedSteps $expectedProgressSteps['Choco']
                    { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextChocoStepPercent)) }
                } else {
                    $null
                }

                Install-WinUtilChoco
                $installResults = Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco -ProgressCallback $chocoStepCallback
                foreach ($r in $installResults) {
                    if (-not $r.Success) {
                        $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                    } elseif ($postInstallCommandById.ContainsKey($r.Program)) {
                        $postInstallName = if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }
                        Write-WinUtilLog -Component "Install" -Message "Running post-install step for $postInstallName`: $($postInstallCommandById[$r.Program])"
                        try {
                            & ([scriptblock]::Create($postInstallCommandById[$r.Program]))
                            Write-WinUtilLog -Component "Install" -Message "$postInstallName post-install step completed"
                        } catch {
                            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Post-install step failed for ${postInstallName}: $_"
                        }
                    }
                }
                $completedPackages += @($packagesChoco).Count
                $completedPercent = $chocoEndPercent
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            foreach ($installBucket in @(
                @{ Packages = $packagesDirect; StepsKey = "Direct"; Installer = { param($pkgs, $cb) Install-WinUtilProgramDirect -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesGithub; StepsKey = "Github"; Installer = { param($pkgs, $cb) Install-WinUtilProgramGithub -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesNpm; StepsKey = "Npm"; Installer = { param($pkgs, $cb) Install-WinUtilProgramNpm -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesWslCommand; StepsKey = "WslCommand"; Installer = { param($pkgs, $cb) Install-WinUtilWSLCommand -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesStreamLinkManager; StepsKey = "StreamLinkManager"; Installer = { param($pkgs, $cb) Install-WinUtilStreamLinkManager -Packages $pkgs -ProgressCallback $cb } }
            )) {
                # @($null).Count is 1, not 0 - see the WSL bucket loop above for why this matters.
                $bucketPackages = @($installBucket.Packages | Where-Object { $_ })

                # One package at a time - see the WSL bucket loop above for why (per-package
                # percent movement plus each installer's own -ProgressCallback milestones).
                foreach ($pkg in $bucketPackages) {
                    $pkgName = $pkg.content
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $pkgName ($position/$totalPackages)" -Percent $startPercent
                    }

                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    $stepCallback = if ($hasUI) {
                        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent $startPercent -EndPercent $completedPercent -ExpectedSteps $expectedProgressSteps[$installBucket.StepsKey]
                        { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextStepPercent)) }
                    } else {
                        $null
                    }

                    & $installBucket.Installer @($pkg) $stepCallback

                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $pkgName ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }

            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            if ($failedPackages.Count -gt 0) {
                $failedList = $failedPackages -join "`n - "
                Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Install workflow completed with failures: $($failedPackages -join ', ')"
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished with errors" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock {
                        Set-WinUtilTaskbaritem -state "None" -overlay "warning"
                        Show-WinUtilMessage -Message "These failed to install - check the log for details:`n - $failedList" -Title "Some installs failed" -Button "OK" -Icon "Warning"
                    }
                }
            } else {
                Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
                }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Install workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }
    }
}
