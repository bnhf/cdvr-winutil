function Test-WinUtilWSLCommandInstalled {
    <#
    .SYNOPSIS
        Returns $true if a wslCommand package's installCheckCommand exits successfully inside
        its distro - used by "Show Installed Apps" for packages with no winget/choco id (e.g.
        Olivetin, installed via a "docker run" command inside WSL rather than a Windows package
        manager, so there's nothing for Test-WinUtilProgramInstalled to look up).

    .DESCRIPTION
        installCheckCommand is data-driven (from applications.json), not hardcoded here, the
        same way command/uninstallCommand already are for wslCommand packages - e.g. Olivetin's
        is "docker inspect olivetin-ezstart", which exits 0 if that named container exists
        (installed, regardless of whether it's currently running) and non-zero if it doesn't.
        Deliberately checks container existence, not "docker ps" (running containers only) -
        a stopped-but-installed container should still count as installed.

        Bounded via Invoke-WinUtilWithTimeout, not run directly, for the same reason every other
        wsl.exe call in this codebase is - it can occasionally hang for reasons unrelated to the
        specific command being run (see Install-WinUtilWSLDistro.ps1 for a confirmed real case).
        A short timeout (this is a lightweight inspect, not a real install operation) that
        defaults to "not installed" on failure - "Show Installed Apps" scanning the whole
        catalog shouldn't stall on one slow/hung check.
    #>
    param(
        [string]$Distro,
        [string]$InstallCheckCommand
    )

    if ([string]::IsNullOrWhiteSpace($Distro) -or [string]::IsNullOrWhiteSpace($InstallCheckCommand)) {
        return $false
    }

    Invoke-WinUtilWithTimeout -TimeoutSeconds 15 -DefaultValue $false -ArgumentList @($Distro, $InstallCheckCommand) -ScriptBlock {
        param($Distro, $InstallCheckCommand)
        try {
            & wsl -d $Distro -- bash -c $InstallCheckCommand *>&1 | Out-Null
            return $LASTEXITCODE -eq 0
        } catch {
            return $false
        }
    }
}
