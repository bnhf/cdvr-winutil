function Test-WinUtilWSLFeatureEnabled {
    <#
    .SYNOPSIS
        Returns $true if the WSL Windows optional feature is enabled.
    #>
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction Stop
        return $feature.State -eq "Enabled"
    } catch {
        return $false
    }
}
