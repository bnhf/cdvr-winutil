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
        on this OS build/environment) is not evidence virtualization is actually unavailable.
    #>
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
