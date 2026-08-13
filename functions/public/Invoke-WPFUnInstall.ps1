function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] Install process is currently running"
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to uninstall"
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = "This will uninstall the following applications:"

    # Unregistering a WSL distro permanently deletes its filesystem, not just "removes" it -
    # worth calling out explicitly here rather than folding it into the generic app list below.
    $wslDataLossPackages = @($PackagesToUninstall | Where-Object { $_.installType -eq "wslFeature" -or $_.installType -eq "wslDistro" })
    if ($wslDataLossPackages.Count -gt 0) {
        $Messageboxbody += "`n`nUninstalling WSL2 and/or a WSL distro permanently deletes that distro's filesystem and all data inside it - this cannot be undone."
    }

    # A native System.Windows.MessageBox (Show-WinUtilMessage) has no way to actually render
    # aligned columns - it uses a proportional font, so an earlier version of this that tried to
    # fake a Name/Description table via Select-Object/Out-String just produced misaligned,
    # unprofessional-looking plain text no matter what the underlying data was. Show-CustomDialog
    # (already used for About/Sponsors) renders each app as a real row instead - bold name,
    # wrapped description underneath - and now supports Yes/No, matching Show-WinUtilMessage's
    # own "Yes"/"No" return convention. Catalog entries use "content"/"description", not
    # "Name"/"Description" - calculated properties pull from the correct source fields while
    # still giving Show-CustomDialog's -Items the Name/Description shape it expects.
    $uninstallItems = $PackagesToUninstall | Select-Object @{Name='Name'; Expression={$_.content}}, @{Name='Description'; Expression={$_.description}}

    $confirm = Show-CustomDialog -Title $MessageboxTitle -Message $Messageboxbody -Items $uninstallItems -Buttons YesNo -Width 480 -Height 450 -EnableScroll $true

    if($confirm -eq "No") {return}

    # Shown right after confirmation, not just once the background runspace starts below - see
    # Invoke-WPFInstall.ps1's matching comment for why (the runspace start + bucket resolution
    # below can itself take a moment with no visible feedback otherwise).
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing uninstall..." -Percent 0

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall requested for $(@($PackagesToUninstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToUninstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $packagesNpm = $packagesSorted['Npm']
        $packagesStreamLinkManager = $packagesSorted['StreamLinkManager']

        # Packages whose uninstall isn't automated - direct/WSL-command packages with no
        # declared uninstallCommand (or, for direct, no uninstallViaInstaller either). Github
        # packages aren't split this way - whether one can be uninstalled depends on a registry
        # lookup at runtime (does its installer register a normal Windows uninstaller?), not a
        # static catalog field, so every selected one is attempted via
        # Uninstall-WinUtilProgramGithub, which logs its own "nothing found" case instead of
        # this being decided upfront.
        $unsupported = [System.Collections.Generic.List[string]]::new()
        $packagesDirect = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['Direct'])) {
            if ($p -and (-not [string]::IsNullOrWhiteSpace($p.uninstallCommand) -or $p.uninstallViaInstaller)) {
                $packagesDirect.Add($p)
            } elseif ($p) {
                $unsupported.Add($p.content)
            }
        }
        $packagesWslCommand = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslCommand'])) {
            if ($p -and -not [string]::IsNullOrWhiteSpace($p.uninstallCommand)) {
                $packagesWslCommand.Add($p)
            } elseif ($p) {
                $unsupported.Add($p.content)
            }
        }
        $packagesGithub = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['Github'])) { if ($p) { $packagesGithub.Add($p) } }
        $packagesWslDistro = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslDistro'])) { if ($p) { $packagesWslDistro.Add($p) } }
        $packagesWslFeature = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslFeature'])) { if ($p) { $packagesWslFeature.Add($p) } }

        $totalPackages = [Math]::Max(1, (@($packagesWinget).Count + @($packagesChoco).Count + @($packagesNpm).Count + @($packagesDirect).Count + @($packagesGithub).Count + @($packagesWslCommand).Count + @($packagesStreamLinkManager).Count + @($packagesWslDistro).Count + @($packagesWslFeature).Count))
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        # winget/choco IDs actually uninstalled don't carry the friendly display name - this maps
        # back to it (falling back to the raw ID) for the failure summary below.
        $packageNameById = @{}
        foreach ($p in $PackagesToUninstall) {
            if ($p.winget -and $p.winget -ne "na") { $packageNameById[$p.winget -replace '^msstore:', ''] = $p.content }
            if ($p.choco -and $p.choco -ne "na") { $packageNameById[$p.choco] = $p.content }
        }
        $failedPackages = [System.Collections.Generic.List[string]]::new()
        Write-WinUtilLog -Component "Uninstall" -Message "Uninstall package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count), npm=$(@($packagesNpm).Count), direct=$(@($packagesDirect).Count), github=$(@($packagesGithub).Count), wslCommand=$(@($packagesWslCommand).Count), streamLinkManager=$(@($packagesStreamLinkManager).Count), wslDistro=$(@($packagesWslDistro).Count), wslFeature=$(@($packagesWslFeature).Count), unsupported=$($unsupported.Count)"

        # See Invoke-WPFInstall.ps1's matching comment for why this exists and what it does.
        # Direct's count (2) covers its higher-step uninstallViaInstaller branch - packages using
        # its lower-step uninstallCommand branch instead just reach the package's end percent on
        # the first (only) call, capped there rather than overshooting; see
        # New-WinUtilStepProgressCallback's own docstring for why a mismatched count is only a
        # cosmetic risk, not a correctness one.
        # See Invoke-WPFInstall.ps1's matching comment for why WslCommand/WslDistro/WslFeature
        # get a higher count than their single initial callback call - they can also ping
        # repeatedly through -OnWaiting while a long operation is still in progress.
        $expectedProgressSteps = @{
            Npm = 1; Direct = 2; Github = 2; WslCommand = 6
            StreamLinkManager = 1; WslDistro = 6; WslFeature = 6; Choco = 1
        }

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app uninstall (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if ($packagesWinget -contains "Microsoft.Edge") {
                New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force
            }

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    $uninstallResults = Install-WinUtilProgramWinget -Action Uninstall -Programs @($program)
                    foreach ($r in $uninstallResults) {
                        if (-not $r.Success) {
                            $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                        }
                    }
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                $chocoEndPercent = [int]((($completedPackages + @($packagesChoco).Count) / $totalPackages) * 100)
                $chocoStepCallback = if ($hasUI) {
                    $nextChocoStepPercent = New-WinUtilStepProgressCallback -StartPercent $startPercent -EndPercent $chocoEndPercent -ExpectedSteps $expectedProgressSteps['Choco']
                    { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextChocoStepPercent)) }
                } else {
                    $null
                }

                $uninstallResults = Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco -ProgressCallback $chocoStepCallback
                foreach ($r in $uninstallResults) {
                    if (-not $r.Success) {
                        $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                    }
                }
                $completedPackages += @($packagesChoco).Count
                $completedPercent = $chocoEndPercent
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            foreach ($uninstallBucket in @(
                @{ Packages = $packagesNpm; StepsKey = "Npm"; Uninstaller = { param($pkgs, $cb) Install-WinUtilProgramNpm -Action Uninstall -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesDirect; StepsKey = "Direct"; Uninstaller = { param($pkgs, $cb) Uninstall-WinUtilProgramDirect -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesGithub; StepsKey = "Github"; Uninstaller = { param($pkgs, $cb) Uninstall-WinUtilProgramGithub -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesWslCommand; StepsKey = "WslCommand"; Uninstaller = { param($pkgs, $cb) Install-WinUtilWSLCommand -Action Uninstall -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesStreamLinkManager; StepsKey = "StreamLinkManager"; Uninstaller = { param($pkgs, $cb) Uninstall-WinUtilStreamLinkManager -Packages $pkgs -ProgressCallback $cb } }
            )) {
                # @($null).Count is 1, not 0 - filtering out falsy entries first means a null or
                # missing bucket is correctly treated as empty here, instead of falling through
                # to the uninstaller call below with $null and crashing on its Mandatory
                # [object[]] parameter ("Cannot bind argument ... because it is null").
                $bucketPackages = @($uninstallBucket.Packages | Where-Object { $_ })

                # One package at a time - see Invoke-WPFInstall.ps1's matching comment for why
                # (per-package percent movement plus each uninstaller's own -ProgressCallback
                # milestones).
                foreach ($pkg in $bucketPackages) {
                    $pkgName = $pkg.content
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $pkgName ($position/$totalPackages)" -Percent $startPercent
                    }

                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    $stepCallback = if ($hasUI) {
                        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent $startPercent -EndPercent $completedPercent -ExpectedSteps $expectedProgressSteps[$uninstallBucket.StepsKey]
                        { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextStepPercent)) }
                    } else {
                        $null
                    }

                    & $uninstallBucket.Uninstaller @($pkg) $stepCallback

                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $pkgName ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }

            # Distro before feature - Uninstall-WinUtilFeatureWSL also unregisters WinUtil's own
            # distro(s) itself, so running the distro bucket first just means that work is
            # already done (and skipped as a no-op) by the time the feature bucket reaches it.
            foreach ($uninstallBucket in @(
                @{ Packages = $packagesWslDistro; StepsKey = "WslDistro"; Uninstaller = { param($pkgs, $cb) Uninstall-WinUtilWSLDistro -Packages $pkgs -ProgressCallback $cb } },
                @{ Packages = $packagesWslFeature; StepsKey = "WslFeature"; Uninstaller = { param($pkgs, $cb) Uninstall-WinUtilFeatureWSL -Packages $pkgs -ProgressCallback $cb } }
            )) {
                $bucketPackages = @($uninstallBucket.Packages | Where-Object { $_ })

                foreach ($pkg in $bucketPackages) {
                    $pkgName = $pkg.content
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $pkgName ($position/$totalPackages)" -Percent $startPercent
                    }

                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    $stepCallback = if ($hasUI) {
                        $nextStepPercent = New-WinUtilStepProgressCallback -StartPercent $startPercent -EndPercent $completedPercent -ExpectedSteps $expectedProgressSteps[$uninstallBucket.StepsKey]
                        { param($message) Set-WinUtilTweaksProgressIndicator -Visible $true -Label $message -Percent ([int](& $nextStepPercent)) }
                    } else {
                        $null
                    }

                    & $uninstallBucket.Uninstaller @($pkg) $stepCallback

                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $pkgName ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }

            if ($unsupported.Count -gt 0) {
                $unsupportedList = $unsupported -join "`n - "
                Write-WinUtilLog -Level "WARN" -Component "Uninstall" -Message "Not uninstalled (no automatic uninstall available): $($unsupported -join ', ')"
                if ($hasUI) {
                    Invoke-WPFUIThread -ScriptBlock {
                        Show-WinUtilMessage -Message "These weren't uninstalled - there's no automatic uninstall for them yet, remove manually if needed:`n - $unsupportedList" -Title "Some apps were skipped" -Button "OK" -Icon "Warning"
                    }
                }
            }

            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            if ($failedPackages.Count -gt 0) {
                $failedList = $failedPackages -join "`n - "
                Write-WinUtilLog -Level "WARN" -Component "Uninstall" -Message "Uninstall workflow completed with failures: $($failedPackages -join ', ')"
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall finished with errors" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock {
                        Set-WinUtilTaskbaritem -state "None" -overlay "warning"
                        Show-WinUtilMessage -Message "These failed to uninstall - check the log for details:`n - $failedList" -Title "Some uninstalls failed" -Button "OK" -Icon "Warning"
                    }
                }
            } else {
                Write-WinUtilLog -Component "Uninstall" -Message "Uninstall workflow completed."
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall finished" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
                }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Uninstall" -Message "Uninstall workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall failed" -Percent 100
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
