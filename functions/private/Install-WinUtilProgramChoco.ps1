function Install-WinUtilProgramChoco {
    <#
    .SYNOPSIS
        Installs or uninstalls the given choco package IDs.

    .DESCRIPTION
        Unlike winget, "choco install" is not upgrade-aware - if a package is already present,
        it just reports "already installed" and exits 0 without changing anything, even when a
        newer version is available. So on Install, the requested IDs are first split by current
        install state (one batched "choco list --local-only" call, not one call per package -
        that per-package-call pattern is exactly what caused the earlier DISM-based slowdown
        elsewhere in this app) and already-installed IDs are routed through "choco upgrade"
        instead, so this behaves like winget's install-or-upgrade semantics.

    .OUTPUTS
        One [pscustomobject] per requested program, each with .Program, .Success, and
        .ExitCode - so callers can report real per-item outcomes instead of assuming every
        attempt succeeded. Choco runs one batched command per install/upgrade/uninstall group
        rather than one call per package, so every program in the same batch shares that
        batch's exit code/outcome - the same granularity choco itself gives us.

    .DESCRIPTION
        ProgressCallback works the same way as Install-WinUtilProgramDirect's - see that
        function's docstring for why it exists. Only fires once per batch (install/upgrade/
        uninstall), matching the granularity described above - there's no per-package signal to
        report mid-batch since choco itself runs the whole group as one process.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs,

        [scriptblock]$ProgressCallback
    )

    $results = [System.Collections.Generic.List[object]]::new()

    if ($Action -eq 'Uninstall') {
        $arguments = "uninstall $Programs -y"
        Write-WinUtilLog -Component "Package" -Message "Uninstall choco package(s): $($Programs -join ', ')"
        if ($ProgressCallback) { try { & $ProgressCallback "Uninstalling via choco: $($Programs -join ', ')..." } catch {} }
        $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "Uninstall choco package(s) completed: $($Programs -join ', ')"
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Uninstall choco package(s) FAILED: $($Programs -join ', ') (exit code: $($process.ExitCode))"
        }
        foreach ($program in $Programs) {
            $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
        }
        return ,$results.ToArray()
    }

    $installedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $localList = & choco list --local-only --limit-output 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $localList) {
                # --limit-output gives "id|version" per line, with no header/footer noise to
                # accidentally match against.
                $id = ($line -split '\|')[0].Trim()
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    [void]$installedIds.Add($id)
                }
            }
        }
    } catch {}
    # If the local-package query itself failed, $installedIds stays empty and everything below
    # falls through to "choco install" - the same no-op-if-already-installed behavior as before,
    # not a regression.

    $toInstall = @($Programs | Where-Object { -not $installedIds.Contains($_) })
    $toUpgrade = @($Programs | Where-Object { $installedIds.Contains($_) })

    if ($toInstall.Count -gt 0) {
        $arguments = "install $toInstall -y"
        Write-WinUtilLog -Component "Package" -Message "Install choco package(s): $($toInstall -join ', ')"
        if ($ProgressCallback) { try { & $ProgressCallback "Installing via choco: $($toInstall -join ', ')..." } catch {} }
        $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "Install choco package(s) completed: $($toInstall -join ', ')"
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Install choco package(s) FAILED: $($toInstall -join ', ') (exit code: $($process.ExitCode))"
        }
        foreach ($program in $toInstall) {
            $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
        }
    }

    if ($toUpgrade.Count -gt 0) {
        $arguments = "upgrade $toUpgrade -y"
        Write-WinUtilLog -Component "Package" -Message "Upgrade already-installed choco package(s): $($toUpgrade -join ', ')"
        if ($ProgressCallback) { try { & $ProgressCallback "Upgrading via choco: $($toUpgrade -join ', ')..." } catch {} }
        $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "Upgrade choco package(s) completed: $($toUpgrade -join ', ')"
        } else {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Upgrade choco package(s) FAILED: $($toUpgrade -join ', ') (exit code: $($process.ExitCode))"
        }
        foreach ($program in $toUpgrade) {
            $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
        }
    }

    return ,$results.ToArray()
}
