function Set-WinUtilNoBomFileContent {
    <#
    .SYNOPSIS
        Writes text to a file as UTF-8 without a byte-order-mark, regardless of PowerShell
        version/host.

    .DESCRIPTION
        Set-Content -Encoding UTF8 is not consistent across PowerShell versions - confirmed
        live: Windows PowerShell 5.1 prepends a BOM (bytes EF BB BF) for "UTF8", PowerShell 7+
        does not, for the exact same command. A BOM at the start of a file bash then reads as a
        script corrupts its first word, since bash doesn't strip it - this is exactly what
        Install-WinUtilWSLCommand.ps1 hit: a WSL install command starting with "docker" failed
        with "command not found", because the actual first bytes bash saw were the BOM followed
        by "docker", not "docker" itself.

        A thin wrapper around [System.IO.File]::WriteAllText with an explicit
        UTF8Encoding($false), rather than calling that directly at each use site - Pester can
        mock a PowerShell function, but not a static .NET method call, so call sites that need
        to be testable (without actually writing through a real \\wsl.localhost UNC path) go
        through this instead of the raw .NET API.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $noBomUtf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Value, $noBomUtf8)
}
