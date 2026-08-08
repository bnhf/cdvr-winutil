function Test-WinUtilWSLFeatureEnabled {
    <#
    .SYNOPSIS
        Returns $true only if WSL2 is actually usable - not just the base "Windows Subsystem
        for Linux" optional feature, but "VirtualMachinePlatform" too.

    .DESCRIPTION
        WSL2 (unlike WSL1) runs on top of a lightweight VM, so it needs both
        Microsoft-Windows-Subsystem-Linux and VirtualMachinePlatform enabled - a system with
        only the first one turned on (e.g. an old manual WSL1 setup, or VirtualMachinePlatform
        disabled independently by policy or Windows Features) would still report "WSL is
        enabled" under the old single-feature check while actually being unable to run a WSL2
        distro. Install-WinUtilFeatureWSL.ps1 already enables both correctly via
        "wsl --install" - this only affects detection, i.e. Show Installed Apps and
        prerequisite checks before installing anything that depends on WSL2.
    #>
    try {
        $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction Stop
        $vmPlatformFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction Stop
        return $wslFeature.State -eq "Enabled" -and $vmPlatformFeature.State -eq "Enabled"
    } catch {
        return $false
    }
}
