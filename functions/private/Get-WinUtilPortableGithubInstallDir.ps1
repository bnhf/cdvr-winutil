function Get-WinUtilPortableGithubInstallDir {
    <#
    .SYNOPSIS
        Returns the fixed per-app folder a "portable" github-install-type package is
        downloaded into and run from.

    .DESCRIPTION
        A "portable" github-install-type package (catalog field "portable": true, e.g. Pluto
        for Channels) is a standalone executable with no setup wizard - confirmed via its own
        repo docs: "Move the .exe to a folder of your choice... doesn't register itself in
        Windows' Add/Remove Programs." Install-WinUtilProgramGithub, Uninstall-WinUtilProgramGithub,
        and Invoke-WinUtilCurrentSystem's "Show Installed Apps" detection all need to agree on
        exactly the same folder for a given app - a single shared helper here, rather than each
        one building the same Join-Path string independently, is what keeps that guaranteed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Join-Path $env:LocalAppData "CDVRWinUtil-Portable\$Name"
}
