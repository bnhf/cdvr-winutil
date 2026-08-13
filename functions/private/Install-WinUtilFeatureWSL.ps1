Function Install-WinUtilFeatureWSL {
    <#
    .SYNOPSIS
        Enables the WSL2 platform feature. First-time enable on many systems requires a
        reboot before WSL is actually usable - this does not claim silent one-click success.

    .DESCRIPTION
        Bounded to several minutes via Invoke-WinUtilWithTimeout, not the few-second default
        used elsewhere for quick DISM/registry checks - "wsl --install" can download the WSL
        kernel/app itself and, on a system where WSL isn't installed yet, can also try to reach
        the Microsoft Store, which can hang for a long time on a slow/absent connection (the
        same real-world quirk Invoke-WinUtilWithTimeout was originally built to guard against
        elsewhere). Verifies success afterward via Test-WinUtilWSLFeatureEnabled rather than
        trusting wsl.exe's own exit behavior - a timeout here isn't necessarily a real failure,
        WSL2 may already be fully enabled underneath it (confirmed live for the sibling distro
        install below: the distro had already finished registering while the wsl.exe call
        itself never returned control to us).

        wsl.exe's output is captured via 2>&1, which wraps stderr lines as [ErrorRecord] rather
        than plain strings, so each is converted to its plain .Exception.Message before
        Out-String sees it - see Install-WinUtilWSLCommand.ps1's docstring for the confirmed real
        case (a genuinely successful install logging what looked like a crash).

        ProgressCallback works the same way as Install-WinUtilWSLCommand's - see that function's
        docstring for why it only needs to cover the gap before -OnWaiting's own updates start.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    foreach ($package in $Packages) {
        $name = $package.content
        Write-WinUtilLog -Component "Package" -Message "Enabling WSL2 ($name)"
        if ($ProgressCallback) { try { & $ProgressCallback "Enabling WSL2..." } catch {} }

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 300 -DefaultValue $null -OnWaitingIntervalSeconds 20 -OnWaiting {
            param($elapsedSeconds)
            Write-WinUtilLog -Component "Package" -Message "Still enabling WSL2 ($($elapsedSeconds)s elapsed) - this can take a while."
            # Routed through -ProgressCallback (when supplied) so each periodic ping during a
            # long wait also nudges the shared progress bar's Percent forward, not just its
            # Label - see New-WinUtilStepProgressCallback's docstring.
            if ($ProgressCallback) {
                try { & $ProgressCallback "Enabling WSL2 ($($elapsedSeconds)s elapsed)..." } catch {}
            } else {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Enabling WSL2 ($($elapsedSeconds)s elapsed)..."
            }
        } -ScriptBlock {
            try {
                return ((& wsl --install --no-distribution 2>&1) | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
                } | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --install --no-distribution did not finish within the expected time - checking whether WSL2 actually enabled anyway."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --install completed with no console output)" })
        }

        # Clears the "uninstalled this session" flag Uninstall-WinUtilFeatureWSL sets, so
        # Test-WinUtilWSLFeatureEnabled goes back to trusting the real DISM/wsl.exe-backed state
        # now that WSL2 has been (re)installed - has to happen before the verification check
        # right below, or that check would still see the stale "uninstalled" flag.
        if ($null -ne $sync) { $sync.WSLRuntimeUninstalled = $false }

        if (Test-WinUtilWSLFeatureEnabled) {
            Write-WinUtilLog -Component "Package" -Message "${name}: WSL2 is enabled and usable."
        } else {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: WSL2 does not appear usable yet - if this is the first time it's been enabled on this machine, a restart is likely required."
        }
    }
}
