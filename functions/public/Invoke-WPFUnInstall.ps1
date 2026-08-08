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

    $ButtonType = "YesNo"
    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = ("This will uninstall the following applications: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = "Information"

    # Unregistering a WSL distro permanently deletes its filesystem, not just "removes" it -
    # worth calling out explicitly here rather than folding it into the generic app list above.
    $wslDataLossPackages = @($PackagesToUninstall | Where-Object { $_.installType -eq "wslFeature" -or $_.installType -eq "wslDistro" })
    if ($wslDataLossPackages.Count -gt 0) {
        $Messageboxbody += "`nUninstalling WSL2 and/or a WSL distro permanently deletes that distro's filesystem and all data inside it - this cannot be undone."
    }

    $confirm = Show-WinUtilMessage -Message $Messageboxbody -Title $MessageboxTitle -Button $ButtonType -Icon $MessageIcon

    if($confirm -eq "No") {return}

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
        # declared uninstallCommand (or, for direct, no uninstallViaInstaller either), plus
        # github (arbitrary third-party installers with no known uninstaller).
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
        foreach ($p in @($packagesSorted['Github'])) { if ($p) { $unsupported.Add($p.content) } }
        $packagesWslDistro = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslDistro'])) { if ($p) { $packagesWslDistro.Add($p) } }
        $packagesWslFeature = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($packagesSorted['WslFeature'])) { if ($p) { $packagesWslFeature.Add($p) } }

        $totalPackages = [Math]::Max(1, (@($packagesWinget).Count + @($packagesChoco).Count + @($packagesNpm).Count + @($packagesDirect).Count + @($packagesWslCommand).Count + @($packagesStreamLinkManager).Count + @($packagesWslDistro).Count + @($packagesWslFeature).Count))
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
        Write-WinUtilLog -Component "Uninstall" -Message "Uninstall package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count), npm=$(@($packagesNpm).Count), direct=$(@($packagesDirect).Count), wslCommand=$(@($packagesWslCommand).Count), streamLinkManager=$(@($packagesStreamLinkManager).Count), wslDistro=$(@($packagesWslDistro).Count), wslFeature=$(@($packagesWslFeature).Count), unsupported=$($unsupported.Count)"

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

                $uninstallResults = Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
                foreach ($r in $uninstallResults) {
                    if (-not $r.Success) {
                        $failedPackages.Add($(if ($packageNameById.ContainsKey($r.Program)) { $packageNameById[$r.Program] } else { $r.Program }))
                    }
                }
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            if ($packagesNpm.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling npm packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilProgramNpm -Action Uninstall -Packages $packagesNpm
                $completedPackages += @($packagesNpm).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled npm packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            if ($packagesDirect.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling direct-install packages ($position/$totalPackages)" -Percent $startPercent
                }

                Uninstall-WinUtilProgramDirect -Packages $packagesDirect
                $completedPackages += @($packagesDirect).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled direct-install packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            if ($packagesWslCommand.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling WSL command packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilWSLCommand -Action Uninstall -Packages $packagesWslCommand
                $completedPackages += @($packagesWslCommand).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled WSL command packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if ($packagesStreamLinkManager.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling Streaming Library Manager ($position/$totalPackages)" -Percent $startPercent
                }

                Uninstall-WinUtilStreamLinkManager -Packages $packagesStreamLinkManager
                $completedPackages += @($packagesStreamLinkManager).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled Streaming Library Manager ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            # Distro before feature - Uninstall-WinUtilFeatureWSL also unregisters WinUtil's own
            # distro(s) itself, so running the distro bucket first just means that work is
            # already done (and skipped as a no-op) by the time the feature bucket reaches it.
            foreach ($uninstallBucket in @(
                @{ Packages = $packagesWslDistro; Label = "WSL distro"; Uninstaller = { param($pkgs) Uninstall-WinUtilWSLDistro -Packages $pkgs } },
                @{ Packages = $packagesWslFeature; Label = "WSL2 feature"; Uninstaller = { param($pkgs) Uninstall-WinUtilFeatureWSL -Packages $pkgs } }
            )) {
                # @($null).Count is 1, not 0 - filtering out falsy entries first means a null or
                # missing bucket is correctly treated as empty here, instead of falling through
                # to the uninstaller call below with $null and crashing on its Mandatory
                # [object[]] parameter ("Cannot bind argument ... because it is null").
                $bucketPackages = @($uninstallBucket.Packages | Where-Object { $_ })
                if ($bucketPackages.Count -eq 0) { continue }

                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $($uninstallBucket.Label) packages ($position/$totalPackages)" -Percent $startPercent
                }

                & $uninstallBucket.Uninstaller $bucketPackages

                $completedPackages += $bucketPackages.Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $($uninstallBucket.Label) packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
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
