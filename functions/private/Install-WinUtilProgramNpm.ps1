Function Install-WinUtilProgramNpm {
    <#
    .SYNOPSIS
        Installs or uninstalls a global npm package. Requires Node.js/npm to already be on
        PATH - packages using this installType should declare "nodejs" in their "requires".
    #>
    param (
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install",

        [Parameter(Mandatory = $true)]
        [object[]]$Packages
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $npmPackage = $package.npmPackage

        if ([string]::IsNullOrWhiteSpace($npmPackage)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm $($Action.ToLower()) for $name is missing npmPackage."
            continue
        }

        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm is not on PATH - can't $($Action.ToLower()) $name."
            continue
        }

        $npmVerb = if ($Action -eq "Uninstall") { "uninstall" } else { "install" }
        Write-WinUtilLog -Component "Package" -Message "$Action $name via npm ($npmPackage)"
        $process = Start-Process -FilePath "npm" -ArgumentList @($npmVerb, "-g", $npmPackage) -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$name npm $($npmVerb) completed (exit code: $($process.ExitCode))"
    }
}
