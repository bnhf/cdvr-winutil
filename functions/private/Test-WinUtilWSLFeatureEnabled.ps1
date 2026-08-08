function Test-WinUtilWSLFeatureEnabled {
    <#
    .SYNOPSIS
        Returns $true only if WSL2 is actually usable - not just the base "Windows Subsystem
        for Linux" optional feature, but "VirtualMachinePlatform" too, and the WSL runtime
        itself.

    .DESCRIPTION
        WSL2 (unlike WSL1) runs on top of a lightweight VM, so it needs both
        Microsoft-Windows-Subsystem-Linux and VirtualMachinePlatform enabled - a system with
        only the first one turned on (e.g. an old manual WSL1 setup, or VirtualMachinePlatform
        disabled independently by policy or Windows Features) would still report "WSL is
        enabled" under a single-feature check while actually being unable to run a WSL2
        distro. Install-WinUtilFeatureWSL.ps1 already enables both correctly via
        "wsl --install" - this only affects detection, i.e. Show Installed Apps and
        prerequisite checks before installing anything that depends on WSL2.

        Also runs "wsl --status" and checks its exit code, not just the optional features -
        "wsl --uninstall" removes the WSL runtime without disabling the optional features, so
        the features alone would still say "Enabled" long after the runtime is actually gone
        (this was reported live: Show Installed Apps said WSL2 was installed, but "wsl --status"
        said "The Windows Subsystem for Linux is not installed" - confirmed on that same machine
        to exit with code 50). Any non-zero exit is treated as "not confidently usable," not just
        50 specifically, since the exact set of failure codes wsl.exe can return isn't fully
        known - the cost of an unnecessary restart prompt or redundant reinstall is far lower
        than silently trusting an absent/broken runtime as fine, which is the bug this fixes.

        Queries the optional features in one unfiltered call and filters the result locally,
        rather than two separate -FeatureName-filtered calls - Get-WindowsOptionalFeature is
        DISM-backed and each call can take several seconds regardless of how narrow the
        filter is, so two calls doubles that cost. "wsl --status" runs inside the same bounded
        call rather than a second one, for the same reason - one round-trip, not two.

        Bounded to a few seconds via Invoke-WinUtilWithTimeout on top of that - DISM/CBS can
        occasionally take far longer than normal (a slow or partially corrupted servicing
        state), and wsl.exe itself can hang trying to reach the Microsoft Store when WSL isn't
        installed. This matters more here than most places: Resolve-WinUtilPrerequisites calls
        this synchronously on the UI thread (it has to, to show its modal dialog), so a slow or
        hung call here froze the whole app rather than just delaying a background operation.

        Checks $sync.WSLRuntimeUninstalled first (set by Uninstall-WinUtilFeatureWSL, cleared by
        Install-WinUtilFeatureWSL) before even querying DISM/wsl.exe - a fast, always-correct
        short-circuit for the one case we can be certain about (we just uninstalled it
        ourselves, this session) without needing either external query at all. This only covers
        uninstalls done through WinUtil in the CURRENT app session though - the "wsl --status"
        check above is what actually covers every other case (a previous session, or WSL2
        removed outside WinUtil entirely), which the flag alone never could.
    #>
    if ($null -ne $sync -and $sync.ContainsKey("WSLRuntimeUninstalled") -and $sync.WSLRuntimeUninstalled) {
        return $false
    }

    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $false -ScriptBlock {
        try {
            $features = Get-WindowsOptionalFeature -Online -ErrorAction Stop
            $wslFeature = $features | Where-Object { $_.FeatureName -eq "Microsoft-Windows-Subsystem-Linux" }
            $vmPlatformFeature = $features | Where-Object { $_.FeatureName -eq "VirtualMachinePlatform" }
            if ($wslFeature.State -ne "Enabled" -or $vmPlatformFeature.State -ne "Enabled") {
                return $false
            }
        } catch {
            return $false
        }

        try {
            & wsl --status 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                return $false
            }
        } catch {
            return $false
        }

        return $true
    }
}
