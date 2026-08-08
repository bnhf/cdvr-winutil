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
        filter is, so two calls doubles that cost.

        Bounded to a few seconds via Invoke-WinUtilWithTimeout on top of that - DISM/CBS can
        occasionally take far longer than normal (a slow or partially corrupted servicing
        state), and this matters more here than most places: Resolve-WinUtilPrerequisites
        calls this synchronously on the UI thread (it has to, to show its modal dialog), so a
        slow or hung DISM call there froze the whole app rather than just delaying a
        background operation.

        Checks $sync.WSLRuntimeUninstalled first (set by Uninstall-WinUtilFeatureWSL, cleared by
        Install-WinUtilFeatureWSL) before even querying DISM - "wsl --uninstall" deliberately
        does not disable these optional features (that's a separate, more disruptive step this
        app doesn't take), so the DISM state alone would still say "Enabled" immediately after
        uninstalling WSL2 through WinUtil, incorrectly treating it as already usable and skipping
        the restart-required gate in Resolve-WinUtilPrerequisites for anything selected in the
        same app session afterward. This only covers uninstalls done through WinUtil in the
        current session, not e.g. a manual "wsl --uninstall" from outside the app or a previous
        session - DISM remains the source of truth for every other case.
    #>
    if ($null -ne $sync -and $sync.ContainsKey("WSLRuntimeUninstalled") -and $sync.WSLRuntimeUninstalled) {
        return $false
    }

    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $false -ScriptBlock {
        try {
            $features = Get-WindowsOptionalFeature -Online -ErrorAction Stop
            $wslFeature = $features | Where-Object { $_.FeatureName -eq "Microsoft-Windows-Subsystem-Linux" }
            $vmPlatformFeature = $features | Where-Object { $_.FeatureName -eq "VirtualMachinePlatform" }
            return $wslFeature.State -eq "Enabled" -and $vmPlatformFeature.State -eq "Enabled"
        } catch {
            return $false
        }
    }
}
