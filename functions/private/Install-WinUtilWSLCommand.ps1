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
            $output = & wsl -d $distro -- bash "/tmp/$scriptName" 2>&1 | Out-String
            Write-WinUtilLog -Component "Package" -Message $output.Trim()
            Write-WinUtilLog -Component "Package" -Message "$name $($Action.ToLower()) completed."
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run $($Action.ToLower()) for ${name}: $_"
        } finally {
            Remove-Item -Path $wslTempPath -Force -ErrorAction SilentlyContinue
        }
    }
}
