Function Uninstall-WinUtilFeatureWSL {
    <#
    .SYNOPSIS
        Uninstalls the WSL2 platform: after confirming with the user, stops and unregisters
        any distro(s) WinUtil's own catalog manages (installType "wslDistro") that are actually
        currently registered, then runs "wsl --uninstall".

    .DESCRIPTION
        No catalog entry currently declares installType "wslDistro" - Debian moved to a normal
        winget install (Debian.Debian) after "wsl --install -d Debian" was confirmed to hang
        waiting on its interactive first-run OOBE prompt, even from a genuinely interactive
        terminal, which switching install mechanisms couldn't fix. This unregister/confirm path
        (and the sibling Install-WinUtilWSLDistro.ps1/Uninstall-WinUtilWSLDistro.ps1) is left in
        place rather than removed, in case a future catalog entry needs it for a distro that
        isn't separately available via winget.

        Only ever unregisters distros declared in WinUtil's own catalog (installType
        "wslDistro") - never anything else that might be registered on this machine, since that
        data isn't ours to delete. Unregistering permanently deletes that distro's filesystem,
        so - unlike every other step here - this specifically asks for a Yes/No confirmation
        before doing it (via Invoke-WPFUIThreadWithResult, since this runs in the background
        install runspace, not the UI thread) rather than treating it as an implicit side effect of
        uninstalling WSL2. Declining leaves the distro registered (orphaned once the WSL runtime
        below is gone, but not deleted) - "wsl --uninstall" doesn't require every distro to be
        gone first; it removes the WSL runtime/app regardless.

        Does not disable the underlying Windows optional features (Microsoft-Windows-Subsystem-
        Linux, VirtualMachinePlatform) - "wsl --uninstall" doesn't touch those, and turning them
        off is a separate, more disruptive step (needs a restart) that isn't done here.

        Bounded via Invoke-WinUtilWithTimeout, not the few-second default used elsewhere for
        quick DISM/registry checks - wsl.exe can occasionally hang for reasons unrelated to this
        specific command (see Install-WinUtilWSLDistro.ps1 for a confirmed real case on the
        install side), and there's no reason to trust --shutdown/--uninstall are immune just
        because they aren't known to hit that exact case.

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

    $ownedDistros = @($sync.configs.applicationsHashtable.Values | Where-Object { $_.installType -eq "wslDistro" })
    $registeredOwnedDistros = @($ownedDistros | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.distro) -and (Test-WinUtilWSLDistroInstalled -Distro $_.distro)
    })

    if ($registeredOwnedDistros.Count -gt 0) {
        $distroNames = ($registeredOwnedDistros | ForEach-Object { $_.content }) -join ", "
        $confirmed = Invoke-WPFUIThreadWithResult -ScriptBlock {
            (Show-WinUtilMessage -Message "Uninstalling WSL2 will also permanently delete the following WSL distro(s) and all data inside them:`n - $distroNames`n`nDelete them now?" -Title "Confirm WSL distro deletion" -Button ([System.Windows.MessageBoxButton]::YesNo) -Icon "Warning") -eq [System.Windows.MessageBoxResult]::Yes
        }

        if ($confirmed) {
            Uninstall-WinUtilWSLDistro -Packages $registeredOwnedDistros -ProgressCallback $ProgressCallback
        } else {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Skipping deletion of $distroNames - declined. Left registered (will become orphaned, not deleted, once the WSL2 runtime below is uninstalled)."
        }
    }

    foreach ($package in $Packages) {
        $name = $package.content
        Write-WinUtilLog -Component "Package" -Message "Uninstalling WSL2 ($name)"
        if ($ProgressCallback) { try { & $ProgressCallback "Uninstalling WSL2..." } catch {} }

        $output = Invoke-WinUtilWithTimeout -TimeoutSeconds 120 -DefaultValue $null -OnWaitingIntervalSeconds 20 -OnWaiting {
            param($elapsedSeconds)
            Write-WinUtilLog -Component "Package" -Message "Still uninstalling WSL2 ($($elapsedSeconds)s elapsed)."
            # Routed through -ProgressCallback (when supplied) so each periodic ping during a
            # long wait also nudges the shared progress bar's Percent forward, not just its
            # Label - see New-WinUtilStepProgressCallback's docstring.
            if ($ProgressCallback) {
                try { & $ProgressCallback "Uninstalling WSL2 ($($elapsedSeconds)s elapsed)..." } catch {}
            } else {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling WSL2 ($($elapsedSeconds)s elapsed)..."
            }
        } -ScriptBlock {
            try {
                & wsl --shutdown 2>&1 | Out-Null
                return ((& wsl --uninstall 2>&1) | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
                } | Out-String).Trim()
            } catch {
                return $null
            }
        }

        if ($null -eq $output) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "wsl --uninstall did not finish within the expected time."
        } else {
            Write-WinUtilLog -Component "Package" -Message $(if ($output) { $output } else { "(wsl --uninstall completed with no console output)" })
        }
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "${name}: this removes the WSL runtime, not the underlying Windows optional features (Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform) - turn those off separately in Windows Features if you want WSL2 fully disabled."
        # The optional features stay "Enabled" per DISM even though the runtime is now gone
        # (see above) - flag this so Test-WinUtilWSLFeatureEnabled doesn't keep reporting
        # WSL2 as usable for the rest of this app session. Set unconditionally (not gated on
        # $output being non-null) - we attempted the uninstall regardless of whether it
        # finished within the timeout, and the safer assumption is "no longer trustworthy as
        # enabled" rather than risk the opposite mistake again.
        if ($null -ne $sync) { $sync.WSLRuntimeUninstalled = $true }
    }
}
