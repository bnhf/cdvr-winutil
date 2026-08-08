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

    # Prerequisite checks and value prompts show modal dialogs, so they must run here on the
    # UI thread - before the selection is handed off to the background install runspace.
    $PackagesToInstall = Resolve-WinUtilPrerequisites -PackagesToInstall $PackagesToInstall
    $PackagesToInstall = Resolve-WinUtilPackagePrompts -PackagesToInstall $PackagesToInstall

    if ($PackagesToInstall.Count -eq 0) {
        Write-WinUtilLog -Component "Install" -Message "Nothing left to install after prerequisite/prompt resolution."
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
        Write-WinUtilLog -Component "Install" -Message "Install package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count), direct=$(@($packagesDirect).Count), github=$(@($packagesGithub).Count), npm=$(@($packagesNpm).Count), wslFeature=$(@($packagesWslFeature).Count), wslDistro=$(@($packagesWslDistro).Count), wslCommand=$(@($packagesWslCommand).Count), streamLinkManager=$(@($packagesStreamLinkManager).Count)"

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

            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Install-WinUtilWinget
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    Install-WinUtilProgramWinget -Action Install -Programs @($program)
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

                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            foreach ($installBucket in @(
                @{ Packages = $packagesWslFeature; Label = "WSL2 feature"; Installer = { param($pkgs) Install-WinUtilFeatureWSL -Packages $pkgs } },
                @{ Packages = $packagesWslDistro; Label = "WSL distro"; Installer = { param($pkgs) Install-WinUtilWSLDistro -Packages $pkgs } },
                @{ Packages = $packagesDirect; Label = "direct-download"; Installer = { param($pkgs) Install-WinUtilProgramDirect -Packages $pkgs } },
                @{ Packages = $packagesGithub; Label = "GitHub release"; Installer = { param($pkgs) Install-WinUtilProgramGithub -Packages $pkgs } },
                @{ Packages = $packagesNpm; Label = "npm"; Installer = { param($pkgs) Install-WinUtilProgramNpm -Packages $pkgs } },
                @{ Packages = $packagesWslCommand; Label = "WSL command"; Installer = { param($pkgs) Install-WinUtilWSLCommand -Packages $pkgs } },
                @{ Packages = $packagesStreamLinkManager; Label = "Streaming Library Manager"; Installer = { param($pkgs) Install-WinUtilStreamLinkManager -Packages $pkgs } }
            )) {
                if (@($installBucket.Packages).Count -eq 0) { continue }

                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $($installBucket.Label) packages ($position/$totalPackages)" -Percent $startPercent
                }

                & $installBucket.Installer $installBucket.Packages

                $completedPackages += @($installBucket.Packages).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $($installBucket.Label) packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
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
