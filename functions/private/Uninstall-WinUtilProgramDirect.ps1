Function Uninstall-WinUtilProgramDirect {
    <#
    .SYNOPSIS
        Uninstalls a "direct" install-type package, either via a declared uninstallCommand
        (a native PowerShell command string, for packages with a known safe uninstall) or by
        re-launching the same installer used to install it, when the installer itself detects
        an existing install and offers to uninstall (uninstallViaInstaller: true) - the
        correct approach for apps with no separate uninstaller, since we can't reliably infer
        everything a vendor's own installer cleans up.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content

        if (-not [string]::IsNullOrWhiteSpace($package.uninstallCommand)) {
            Write-WinUtilLog -Component "Package" -Message "Uninstalling $name"
            try {
                & ([scriptblock]::Create($package.uninstallCommand))
                Write-WinUtilLog -Component "Package" -Message "$name uninstalled."
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall ${name}: $_"
            }
            continue
        }

        if ($package.uninstallViaInstaller -and -not [string]::IsNullOrWhiteSpace($package.url)) {
            $url = $package.url
            $ext = [IO.Path]::GetExtension($url)
            if ([string]::IsNullOrEmpty($ext)) { $ext = ".exe" }
            $dest = Join-Path $env:TEMP "$name-uninstall$ext"

            Write-WinUtilLog -Component "Package" -Message "Downloading $name installer (for uninstall) from $url"
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to download ${name}: $_"
                continue
            }

            Write-WinUtilLog -Component "Package" -Message "Launching $name installer - it should detect the existing install and offer to uninstall. Stop $name first if it's running, then choose Uninstall in the window that opens. WinUtil will not wait for it to close."
            try {
                $proc = Start-Process -FilePath $dest -PassThru
                Set-WinUtilProcessForeground -Process $proc
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to launch uninstaller for ${name}: $_"
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$name has no uninstallCommand or uninstallViaInstaller defined - not uninstalled."
    }
}
