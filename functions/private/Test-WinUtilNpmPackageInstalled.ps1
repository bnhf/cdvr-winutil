function Test-WinUtilNpmPackageInstalled {
    <#
    .SYNOPSIS
        Returns $true if a global npm package is installed - used by "Show Installed Apps" for
        installType "npm" packages (e.g. Prismcast), which have no winget/choco id to look up.

    .DESCRIPTION
        "npm list -g <package> --depth=0" exits 0 (and lists it) when installed, non-zero when
        it isn't - the standard npm-native way to check, rather than assuming every npm package
        exposes some particular binary/file on disk that would need per-package knowledge.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NpmPackage
    )

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        & npm list -g $NpmPackage --depth=0 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}
