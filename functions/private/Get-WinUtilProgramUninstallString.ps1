function Get-WinUtilProgramUninstallString {
    <#
    .SYNOPSIS
        Looks up a program's registered uninstall command from Windows' own Add/Remove Programs
        registry, by DisplayName wildcard match - for packages with no known winget/choco id, so
        there's nothing for winget/choco to uninstall by ID, but whose installer registers a
        normal Windows uninstaller anyway (most standard installer frameworks - Inno Setup, NSIS,
        WiX/MSI - do this automatically; confirmed for Clicker specifically via its own repo
        docs: "the installer registers an uninstaller").

    .DESCRIPTION
        Scans the per-machine Uninstall key in both its 64-bit and 32-bit (WOW6432Node) views,
        plus the per-user one, since a program can register in whichever matches its install
        scope. Requires EXACTLY one match - zero means nothing is registered under that name
        (already uninstalled, or this particular app doesn't self-register, in which case the
        caller has no way to uninstall it here), and more than one is ambiguous enough that
        guessing could run the wrong program's uninstaller, so this refuses to pick either way
        rather than risk that.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayNamePattern
    )

    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    try {
        $candidates = @(Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $DisplayNamePattern -and -not [string]::IsNullOrWhiteSpace($_.UninstallString) })

        if ($candidates.Count -eq 0) {
            return [pscustomobject]@{
                UninstallString = $null
                Reason = "No program matching '$DisplayNamePattern' found in Windows' Add/Remove Programs list - it may already be uninstalled, or this app doesn't register a standard uninstaller."
            }
        }

        if ($candidates.Count -gt 1) {
            return [pscustomobject]@{
                UninstallString = $null
                Reason = "Found $($candidates.Count) programs matching '$DisplayNamePattern' in Add/Remove Programs - not guessing which one to uninstall."
            }
        }

        return [pscustomobject]@{ UninstallString = $candidates[0].UninstallString; Reason = $null }
    } catch {
        return [pscustomobject]@{ UninstallString = $null; Reason = "Failed to query Add/Remove Programs: $_" }
    }
}
