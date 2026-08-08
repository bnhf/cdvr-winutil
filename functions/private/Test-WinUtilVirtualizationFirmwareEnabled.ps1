function Test-WinUtilVirtualizationFirmwareEnabled {
    <#
    .SYNOPSIS
        Returns $true/$false when hardware virtualization (Intel VT-x / AMD-V) is known to be
        enabled or disabled in firmware, or $null when it can't be determined.

    .DESCRIPTION
        WSL2 - and everything built on it here (Debian, Docker Desktop's WSL2 backend,
        Olivetin) - needs this even when both required Windows optional features are enabled;
        without it, WSL2 fails to start with error 0x80370102. Unlike the optional features,
        this is a firmware/BIOS-UEFI setting that can't be enabled from software, so callers
        should treat this as informational for warning the user, not something to silently
        "fix" - only a definite $false should block anything, since a $null (property missing
        on this OS build/environment, or the query timing out below) is not evidence
        virtualization is actually unavailable.

        Bounded to a few seconds via Invoke-WinUtilWithTimeout - WMI/CIM queries can
        occasionally hang (e.g. a corrupted WMI repository), and this is called synchronously
        on the UI thread by Resolve-WinUtilPrerequisites (it has to, to show its modal
        dialog), so a hang here would freeze the whole app rather than just delay a background
        operation. A timeout returns $null (same as any other "couldn't determine" case), not
        $false - it isn't evidence virtualization is disabled, just that this particular query
        didn't come back in time.
    #>
    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $null -ScriptBlock {
        try {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $cpu -or $null -eq $cpu.VirtualizationFirmwareEnabled) {
                return $null
            }
            return [bool]$cpu.VirtualizationFirmwareEnabled
        } catch {
            return $null
        }
    }
}
