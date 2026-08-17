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

        Checks Win32_ComputerSystem.HypervisorPresent before Win32_Processor's own
        VirtualizationFirmwareEnabled, not instead of it. Author-reported false positive: this
        popped up "virtualization is disabled" on a fresh Windows 11 install with virtualization
        genuinely enabled in the BIOS. VirtualizationFirmwareEnabled is a documented, real WMI
        quirk (multiple independent reports, not this project's own guess) - it goes unreliable,
        specifically reporting $false, once a hypervisor is already active on top of the CPU's
        VT-x/AMD-V extensions, because at that point the hypervisor - not this property - is
        what's actually reflecting hardware state. Modern Windows 11 ships with Virtualization-
        Based Security (Core Isolation) on by default on most current hardware, meaning a
        hypervisor is very often already running from first boot, before WSL2/Hyper-V is ever
        touched - so this false positive isn't an edge case on new hardware, it's close to the
        default. HypervisorPresent reporting $true is direct, unambiguous proof virtualization
        works (a hypervisor cannot run without it), checked first and short-circuits to $true
        without needing the firmware flag at all. Does not fully close every possible false
        negative on its own - some reports describe VirtualizationFirmwareEnabled misreporting
        even with no hypervisor active at all, apparently a genuine firmware/OS reporting bug on
        specific hardware unrelated to this - but it directly fixes the common, predictable case
        this was actually reported for.
    #>
    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $null -ScriptBlock {
        try {
            $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
            if ($computerSystem -and $computerSystem.HypervisorPresent) {
                return $true
            }

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
