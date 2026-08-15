Function Install-WinUtilProgramGithub {
    <#
    .SYNOPSIS
        Downloads and runs the newest matching release asset from a GitHub repo - for
        Channels DVR community projects not published to winget/choco.

    .DESCRIPTION
        De-elevated the same way, and for the same reason, as Install-WinUtilProgramDirect -
        see that function's own docstring. ProgressCallback works the same way too - see that
        function's docstring for why it exists.

        postInstallCommand runs after a successful install, same idea as the winget/choco/npm
        paths (a raw PowerShell command string, executed via [scriptblock]::Create) - added for
        Clicker specifically, whose Rust/WinUI3 executable needs the Microsoft Visual C++
        Redistributable to actually run ("VCRUNTIME140.dll was not found" otherwise), which
        Clicker's own installer doesn't bundle or check for. Handled here rather than via a
        separate "requires" catalog entry, since that would surface as its own visible/
        selectable checkbox rather than something silently pulled in as part of installing
        Clicker. For the MSI branch, only runs if msiexec reported success; for the no-args
        interactive branch, runs regardless, since that launch is fire-and-forget and never
        gives a reliable success signal to gate on - installing the redistributable in parallel
        is idempotent and harmless even if the user hasn't finished Clicker's own setup wizard
        yet by the time it runs.

        Asset selection (which release asset actually gets downloaded, when assetPattern matches
        more than one) is delegated to Select-WinUtilGithubReleaseAsset - see that function's own
        docstring. Added after Clicker's release started publishing both
        "Clicker-Setup-<version>.exe" and "Clicker-Setup-<version>-arm64.exe": the previous plain
        "first match wins" logic isn't architecture-aware at all, and confirmed live to hand a
        user on ordinary x64 hardware an installer that can't run there.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    $headers = @{ "User-Agent" = "cdvr-winutil" }

    # Invoke-WebRequest's default live progress-bar rendering redraws on every buffer chunk and
    # can slow a large download by 10-100x (well-documented PowerShell behavior, worst on
    # Windows PowerShell 5.1) - these installer assets are often 50-150MB. Function-local, so it
    # reverts automatically for the caller once this function returns.
    $ProgressPreference = 'SilentlyContinue'

    foreach ($package in $Packages) {
        $name = $package.content
        $repo = $package.repo
        $assetPattern = $package.assetPattern

        if ([string]::IsNullOrWhiteSpace($repo) -or [string]::IsNullOrWhiteSpace($assetPattern)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "GitHub install for $name is missing repo/assetPattern."
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Querying latest release for $repo"
        if ($ProgressCallback) { try { & $ProgressCallback "Checking latest release for $name..." } catch {} }
        $release = $null
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -TimeoutSec 30
        } catch {
            # /releases/latest 404s when the repo's newest release is marked prerelease
            # (e.g. RustDVR's only release, v0.0.1) - fall back to the full release list.
            try {
                $allReleases = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Headers $headers -TimeoutSec 30
                $release = $allReleases | Select-Object -First 1
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to query releases for ${repo}: $_"
                continue
            }
        }

        if (-not $release) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "No releases found for $repo"
            continue
        }

        $matchingAssets = @($release.assets | Where-Object { $_.name -like $assetPattern })
        $asset = Select-WinUtilGithubReleaseAsset -MatchingAssets $matchingAssets
        if (-not $asset) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "No asset matching '$assetPattern' found in latest release of $repo"
            continue
        }

        $dest = Join-Path $env:TEMP $asset.name
        Write-WinUtilLog -Component "Package" -Message "Downloading $($asset.name) for $name"
        if ($ProgressCallback) { try { & $ProgressCallback "Downloading $name..." } catch {} }
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing -TimeoutSec 120
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to download ${name}: $_"
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing $name"
        if ($ProgressCallback) { try { & $ProgressCallback "Installing $name..." } catch {} }
        try {
            if ($dest -like "*.msi") {
                $process = Start-WinUtilProcessAsStandardUser -FilePath "msiexec.exe" -ArgumentList @("/i `"$dest`"")
                Write-WinUtilLog -Component "Package" -Message "$name installed."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue

                if ($process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($package.postInstallCommand)) {
                    Write-WinUtilLog -Component "Package" -Message "Running post-install step for $name`: $($package.postInstallCommand)"
                    try {
                        & ([scriptblock]::Create($package.postInstallCommand))
                        Write-WinUtilLog -Component "Package" -Message "$name post-install step completed"
                    } catch {
                        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Post-install step failed for ${name}: $_"
                    }
                }
            } elseif ($package.portable) {
                # "portable" (e.g. Pluto for Channels) means the asset itself is the app - no
                # setup wizard, no Add/Remove Programs registration (confirmed via its own repo
                # docs: "Move the .exe to a folder of your choice... doesn't register itself").
                # Running it straight out of %TEMP%, like the plain interactive branch below
                # does, would leave it with no persistent home to relaunch from later and
                # nothing for Uninstall-WinUtilProgramGithub to find - move it into a fixed
                # per-app folder instead, the same idea Install-WinUtilStreamLinkManager uses.
                $installDir = Get-WinUtilPortableGithubInstallDir -Name $name

                # Stop a previous run of this exact install first, so a reinstall/update isn't
                # blocked by the old file being locked open, via Stop-WinUtilProcessByAssetPattern
                # - see that function's own docstring for the full history of why (two
                # PowerShell-side Get-Process approaches, then a first taskkill /IM attempt, were
                # all confirmed live to still silently miss Pluto for Channels' actual running
                # process before the real cause was pinned down: /IM doesn't actually support
                # wildcards at all, contrary to how it's often described).
                if ($assetPattern) {
                    Stop-WinUtilProcessByAssetPattern -AssetPattern $assetPattern
                    # A brief fixed pause, not a poll - taskkill's own termination is synchronous,
                    # but the OS can lag slightly releasing a just-killed process's file handles.
                    Start-Sleep -Milliseconds 500
                }

                New-Item -ItemType Directory -Path $installDir -Force | Out-Null
                $persistentPath = Join-Path $installDir $asset.name
                Move-Item -Path $dest -Destination $persistentPath -Force

                if (Start-WinUtilProcessAsStandardUserNoWait -FilePath $persistentPath) {
                    Write-WinUtilLog -Component "Package" -Message "$name installed to $installDir and launched."
                } else {
                    $proc = Start-Process -FilePath $persistentPath -PassThru
                    Set-WinUtilProcessForeground -Process $proc
                    Write-WinUtilLog -Component "Package" -Message "$name installed to $installDir and launched."
                }

                if (-not [string]::IsNullOrWhiteSpace($package.postInstallCommand)) {
                    Write-WinUtilLog -Component "Package" -Message "Running post-install step for $name`: $($package.postInstallCommand)"
                    try {
                        & ([scriptblock]::Create($package.postInstallCommand))
                        Write-WinUtilLog -Component "Package" -Message "$name post-install step completed"
                    } catch {
                        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Post-install step failed for ${name}: $_"
                    }
                }
            } else {
                # No known silent-install flag for these community-released installers, so this
                # runs interactively - and some interactive installers launch a long-running
                # application on completion that never exits, which would make waiting for it
                # block forever. Launch and move on instead of waiting; don't delete the
                # downloaded file since the process may still be reading it after we return.
                if (Start-WinUtilProcessAsStandardUserNoWait -FilePath $dest) {
                    Write-WinUtilLog -Component "Package" -Message "$name installer launched - it may need you to finish a setup wizard. WinUtil will not wait for it to close."
                } else {
                    $proc = Start-Process -FilePath $dest -PassThru
                    Set-WinUtilProcessForeground -Process $proc
                    Write-WinUtilLog -Component "Package" -Message "$name installer launched - it may need you to finish a setup wizard. WinUtil will not wait for it to close."
                }

                if (-not [string]::IsNullOrWhiteSpace($package.postInstallCommand)) {
                    Write-WinUtilLog -Component "Package" -Message "Running post-install step for $name`: $($package.postInstallCommand)"
                    try {
                        & ([scriptblock]::Create($package.postInstallCommand))
                        Write-WinUtilLog -Component "Package" -Message "$name post-install step completed"
                    } catch {
                        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Post-install step failed for ${name}: $_"
                    }
                }
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run installer for ${name}: $_"
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
    }
}
