Function Install-WinUtilWSLCommand {
    <#
    .SYNOPSIS
        Runs a bash command inside a WSL distro, substituting any {{NAME}} tokens with
        values collected earlier (via Resolve-WinUtilPackagePrompts, on the UI thread).

    .DESCRIPTION
        The command is written to a temp .sh file and placed into the target distro via
        its \\wsl.localhost UNC path, then executed as a script - this avoids the nested
        quoting problems of passing a command with embedded $(...) and quotes through
        `wsl -d <distro> -- bash -c "..."`.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $distro = $package.distro
        $command = $package.command

        if ([string]::IsNullOrWhiteSpace($distro) -or [string]::IsNullOrWhiteSpace($command)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "WSL command install for $name is missing distro/command."
            continue
        }

        foreach ($promptValue in $package.PromptValues.GetEnumerator()) {
            $command = $command.Replace("{{$($promptValue.Key)}}", $promptValue.Value)
        }

        $scriptName = "cdvr-$($package.Key).sh"
        $wslTempPath = "\\wsl.localhost\$distro\tmp\$scriptName"

        Write-WinUtilLog -Component "Package" -Message "Running $name inside WSL distro $distro"
        try {
            Set-Content -Path $wslTempPath -Value $command -NoNewline -Encoding UTF8 -ErrorAction Stop
            $output = & wsl -d $distro -- bash "/tmp/$scriptName" 2>&1 | Out-String
            Write-WinUtilLog -Component "Package" -Message $output.Trim()
            Write-WinUtilLog -Component "Package" -Message "$name completed."
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run ${name}: $_"
        } finally {
            Remove-Item -Path $wslTempPath -Force -ErrorAction SilentlyContinue
        }
    }
}
