function Set-WinUtilDockerDesktopPreferences {
    <#
    .SYNOPSIS
        Sets Docker Desktop's "start at login", "open Dashboard on startup", and "WSL default
        distro integration" preferences, right after its first launch.

    .DESCRIPTION
        Docker Desktop's own preferences live in a per-user JSON file
        (%APPDATA%\Docker\settings-store.json on Docker Desktop 4.35+, settings.json on older
        versions) that Docker itself creates and writes on first run - there is no documented
        schema for it (unlike the separate, enterprise-only admin-settings.json used by Settings
        Management, which doesn't cover these particular preferences at all). The key names used
        here - autoStart, openUIOnStartupDisabled, enableIntegrationWithDefaultWslDistro - come
        from a real settings.json a user shared for troubleshooting, cross-checked against
        enableIntegrationWithDefaultWslDistro, which IS documented as part of
        admin-settings.json's wslIntegration schema. Not confirmed against a live installed copy
        in this environment.

        Must run after Docker Desktop has already been launched once (the caller's job - see
        applications.json's dockerdesktop postInstallCommand) - the settings file doesn't exist
        until Docker Desktop itself creates it on first run, and cannot be pre-seeded with
        confidence, since an incomplete/partial file might not be handled gracefully by an
        undocumented format. Polls for the file to appear rather than assuming a fixed delay,
        since first-run initialization time varies a lot (WSL2 VM setup, image pulls) and can
        take over a minute on a fresh install.

        Closes Docker Desktop before editing the file and relaunches it afterward - editing while
        it's still running risks it overwriting the change with its own next write (this file's
        write timing isn't documented, so there's nothing safer to key off), and the shutdown is
        intentionally forceful (Stop-Process, not a graceful quit) since this runs immediately
        after a fresh install, before anything is using Docker that a hard stop could disrupt.
        Relaunched afterward (in a finally block, so this happens even if the edit itself fails)
        so the net effect matches the caller's original reason for launching it in the first
        place - the Docker engine actually running post-install - not just changed preferences.

        Best-effort throughout, matching every other postInstallCommand in this catalog: if
        Docker Desktop's onboarding flow (EULA/sign-in) blocks the engine from starting - a real
        possibility on a fresh install this function cannot detect or click through - the
        settings file may never appear within the timeout, in which case this logs a warning and
        returns without throwing, leaving the preferences at Docker's own defaults rather than
        failing the whole install.
    #>
    param(
        [string]$DockerExePath = (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        [bool]$StartAtLogin = $true,
        [bool]$OpenDashboardOnStartup = $false,
        [bool]$EnableDefaultWslIntegration = $true,
        [int]$TimeoutSeconds = 120
    )

    $settingsPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
    $legacySettingsPath = Join-Path $env:APPDATA 'Docker\settings.json'

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path $settingsPath) -and -not (Test-Path $legacySettingsPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }

    $targetPath = if (Test-Path $settingsPath) { $settingsPath } elseif (Test-Path $legacySettingsPath) { $legacySettingsPath } else { $null }
    if (-not $targetPath) {
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Docker Desktop's settings file never appeared within ${TimeoutSeconds}s - it may still be waiting on first-run setup (EULA/sign-in). Set start-at-login, dashboard-on-startup, and WSL integration manually in Docker Desktop's own Settings once it's finished."
        return
    }

    # Give it a moment past the file's first appearance before touching it - Docker Desktop may
    # still be writing its initial defaults out.
    Start-Sleep -Seconds 5

    try {
        Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        $settings = Get-Content -Path $targetPath -Raw | ConvertFrom-Json
        $settings | Add-Member -NotePropertyName "autoStart" -NotePropertyValue $StartAtLogin -Force
        $settings | Add-Member -NotePropertyName "openUIOnStartupDisabled" -NotePropertyValue (-not $OpenDashboardOnStartup) -Force
        $settings | Add-Member -NotePropertyName "enableIntegrationWithDefaultWslDistro" -NotePropertyValue $EnableDefaultWslIntegration -Force
        $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $targetPath -Encoding UTF8

        Write-WinUtilLog -Component "Package" -Message "Docker Desktop preferences updated: start at login=$StartAtLogin, open Dashboard on startup=$OpenDashboardOnStartup, WSL default-distro integration=$EnableDefaultWslIntegration."
    } catch {
        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to update Docker Desktop's settings file: $_"
    } finally {
        if (Test-Path $DockerExePath) {
            Start-Process $DockerExePath
        }
    }
}
