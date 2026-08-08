Function Install-WinUtilWSLCommand {
    <#
    .SYNOPSIS
        Runs a bash command inside a WSL distro - the install command with {{NAME}} tokens
        substituted from values collected earlier (via Resolve-WinUtilPackagePrompts, on the
        UI thread), or the uninstallCommand as-is when -Action Uninstall.

    .DESCRIPTION
        The command is written to a temp .sh file and placed into the target distro via
        its \\wsl.localhost UNC path, then executed as a script - this avoids the nested
        quoting problems of passing a command with embedded $(...) and quotes through
        `wsl -d <distro> -- bash -c "..."`.

        Bounded to several minutes via Invoke-WinUtilWithTimeout, not the few-second default
        used elsewhere for quick DISM/registry checks - these commands can do real work (e.g.
        pulling a Docker image) that legitimately takes a while, and wsl.exe itself can hang for
        unrelated reasons (see Install-WinUtilWSLDistro.ps1 for a confirmed real case). Unlike
        that function, there's no independent way to verify an arbitrary command's success after
        a timeout, so a timeout here is logged as a real, if inconclusive, warning rather than
        silently assumed fine.
    #>
    param (
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install",

        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $distro = $package.distro
        $command = if ($Action -eq "Uninstall") { $package.uninstallCommand } else { $package.command }

        if ([string]::IsNullOrWhiteSpace($distro) -or [string]::IsNullOrWhiteSpace($command)) {
            if ($Action -eq "Uninstall") {
                Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name has no uninstallCommand defined - not uninstalled. Remove it manually if needed."
            } else {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "WSL command install for $name is missing distro/command."
            }
            continue
        }

        if ($package.PromptValues) {
            foreach ($promptValue in $package.PromptValues.GetEnumerator()) {
                $command = $command.Replace("{{$($promptValue.Key)}}", $promptValue.Value)
            }
        }

        $scriptName = "cdvr-$($package.Key)-$($Action.ToLower()).sh"
        $wslTempPath = "\\wsl.localhost\$distro\tmp\$scriptName"

        Write-WinUtilLog -Component "Package" -Message "Running $name $($Action.ToLower()) inside WSL distro $distro"
        try {
            Set-Content -Path $wslTempPath -Value $command -NoNewline -Encoding UTF8 -ErrorAction Stop

            $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 300 -DefaultValue $null -ArgumentList @($distro, $scriptName) -OnWaitingIntervalSeconds 20 -OnWaiting {
                param($elapsedSeconds)
                Write-WinUtilLog -Component "Package" -Message "Still running $name $($Action.ToLower()) inside WSL ($($elapsedSeconds)s elapsed) - this can take a while."
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Running $name $($Action.ToLower()) ($($elapsedSeconds)s elapsed)..."
            } -ScriptBlock {
                param($distro, $scriptName)
                try {
                    return (& wsl -d $distro -- bash "/tmp/$scriptName" 2>&1 | Out-String).Trim()
                } catch {
                    return $null
                }
            }

            if ($null -eq $output) {
                Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name $($Action.ToLower()) did not finish within the expected time - it may still be running inside WSL, or may need interactive input this app can't provide."
            } else {
                Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(command completed with no console output)" })
                Write-WinUtilLog -Component "Package" -Message "$name $($Action.ToLower()) completed."
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run $($Action.ToLower()) for ${name}: $_"
        } finally {
            Remove-Item -Path $wslTempPath -Force -ErrorAction SilentlyContinue
        }
    }
}
