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
        enabled" under a single-feature check while actually being unable to run a WSL2
        distro. Install-WinUtilFeatureWSL.ps1 already enables both correctly via
        "wsl --install" - this only affects detection, i.e. Show Installed Apps and
        prerequisite checks before installing anything that depends on WSL2.

        Queries both features in one unfiltered call and filters the result locally, rather
        than two separate -FeatureName-filtered calls - Get-WindowsOptionalFeature is
        DISM-backed and each call can take several seconds regardless of how narrow the
        filter is, so two calls doubles that cost. This matters because
        Resolve-WinUtilPrerequisites calls this synchronously on the UI thread (it has to, to
        show its modal dialog) before installing anything - two slow DISM round trips there
        made the app appear to hang.
    #>
    try {
        $features = Get-WindowsOptionalFeature -Online -ErrorAction Stop
        $wslFeature = $features | Where-Object { $_.FeatureName -eq "Microsoft-Windows-Subsystem-Linux" }
        $vmPlatformFeature = $features | Where-Object { $_.FeatureName -eq "VirtualMachinePlatform" }
        return $wslFeature.State -eq "Enabled" -and $vmPlatformFeature.State -eq "Enabled"
    } catch {
        return $false
    }
}
