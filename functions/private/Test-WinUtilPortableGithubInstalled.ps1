function Test-WinUtilPortableGithubInstalled {
    <#
    .SYNOPSIS
        Returns $true if a "portable" github-install-type package is present in its fixed
        per-app folder under LocalAppData - used by "Show Installed Apps" for these packages,
        which have no winget/choco id and never register in Add/Remove Programs.

    .DESCRIPTION
        The other two "github" detection signals (webui reachability, an Add/Remove Programs
        entry) both depend on the app currently being reachable/registered - neither works for
        a portable app that's installed but not currently running, since it never registers
        itself anywhere. Install-WinUtilProgramGithub always persists a portable package to
        Get-WinUtilPortableGithubInstallDir's exact folder, so checking there for a file
        matching the catalog's own assetPattern is a reliable, independent third signal.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$AssetPattern
    )

    $installDir = Get-WinUtilPortableGithubInstallDir -Name $Name
    if (-not (Test-Path $installDir)) {
        return $false
    }

    return [bool](Get-ChildItem -Path $installDir -Filter $AssetPattern -ErrorAction SilentlyContinue)
}
