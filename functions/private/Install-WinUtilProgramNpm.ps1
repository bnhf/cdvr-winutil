Function Install-WinUtilProgramNpm {
    <#
    .SYNOPSIS
        Installs a global npm package. Requires Node.js/npm to already be on PATH -
        packages using this installType should declare "nodejs" in their "requires".
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $npmPackage = $package.npmPackage

        if ([string]::IsNullOrWhiteSpace($npmPackage)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm install for $name is missing npmPackage."
            continue
        }

        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm is not on PATH - install Node.js first, then retry $name."
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing $name via npm ($npmPackage)"
        $process = Start-Process -FilePath "npm" -ArgumentList @("install", "-g", $npmPackage) -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$name npm install completed (exit code: $($process.ExitCode))"
    }
}
