Function Install-WinUtilProgramDirect {
    <#
    .SYNOPSIS
        Downloads and runs an installer from a direct URL - for packages with no winget/choco listing.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $url = $package.url
        $installArgs = $package.args

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Direct install for $name is missing a url."
            continue
        }

        $ext = [IO.Path]::GetExtension($url)
        if ([string]::IsNullOrEmpty($ext)) { $ext = ".exe" }
        $dest = Join-Path $env:TEMP "$name$ext"

        Write-WinUtilLog -Component "Package" -Message "Downloading $name from $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to download ${name}: $_"
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing $name"
        try {
            if ($ext -eq ".msi") {
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$dest`" $installArgs" -Wait
            } elseif ([string]::IsNullOrWhiteSpace($installArgs)) {
                # No documented silent-install flag - runs interactively.
                Start-Process -FilePath $dest -Wait
            } else {
                Start-Process -FilePath $dest -ArgumentList $installArgs -Wait
            }
            Write-WinUtilLog -Component "Package" -Message "$name installed."
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run installer for ${name}: $_"
        } finally {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
    }
}
