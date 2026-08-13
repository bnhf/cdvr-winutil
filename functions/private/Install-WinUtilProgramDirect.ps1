Function Install-WinUtilProgramDirect {
    <#
    .SYNOPSIS
        Downloads and runs an installer from a direct URL - for packages with no winget/choco listing.

    .DESCRIPTION
        Runs the installer de-elevated (as the standard user), not inheriting WinUtil's own
        elevated context. Confirmed live this was NOT the case before: WinUtil always
        self-elevates at startup, this function runs inside the install runspace spawned from
        that elevated process, and none of its three Start-Process calls did anything to
        counteract that - so e.g. Channels DVR Server's installer, and the app it leaves running
        afterward, launched as Administrator. That matters beyond just "more privilege than
        needed": an app that installs/runs elevated once can leave behind admin-owned config or
        data it can no longer read/write on a later normal (non-elevated) run.

        Uses Start-WinUtilProcessAsStandardUser (waits, gives a real exit code) for the MSI and
        explicit-args branches, and Start-WinUtilProcessAsStandardUserNoWait for the no-args
        interactive branch - that branch deliberately never waits on the launched process (see
        its own comment below), and Start-WinUtilProcessAsStandardUser's wait-based
        fallback-to-elevated-on-timeout would misfire on a target that's expected to still be
        running, launching it a second time. Falls back to running elevated (with a logged
        warning) if de-elevation itself fails for any reason, the same best-effort philosophy as
        the winget install path.

        ProgressCallback, when supplied, is invoked with a short status string at each milestone
        below (downloading, installing, done) - this function has no other way to report
        progress, since (unlike the WSL-invoking installers) there's no periodic -OnWaiting
        callback for a plain Invoke-WebRequest/Start-Process call. Invoke-WPFInstall.ps1 wires
        this to the shared window-level progress indicator so its label changes mid-install
        instead of sitting frozen on "Installing X" for however long the download/install
        actually takes.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    foreach ($package in $Packages) {
        $name = $package.content
        $url = $package.url
        $installArgs = $package.args

        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Direct install for $name is missing a url."
            continue
        }

        $ext = [IO.Path]::GetExtension($url)
        if ([string]::IsNullOrEmpty($ext)) { $ext = ".exe" }
        $dest = Join-Path $env:TEMP "$name$ext"

        Write-WinUtilLog -Component "Package" -Message "Downloading $name from $url"
        if ($ProgressCallback) { try { & $ProgressCallback "Downloading $name..." } catch {} }
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to download ${name}: $_"
            continue
        }

        Write-WinUtilLog -Component "Package" -Message "Installing $name"
        if ($ProgressCallback) { try { & $ProgressCallback "Installing $name..." } catch {} }
        try {
            if ($ext -eq ".msi") {
                Start-WinUtilProcessAsStandardUser -FilePath "msiexec.exe" -ArgumentList @("/i `"$dest`" $installArgs") | Out-Null
                Write-WinUtilLog -Component "Package" -Message "$name installed."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            } elseif ([string]::IsNullOrWhiteSpace($installArgs)) {
                # No documented silent-install flag, so this runs interactively - and some
                # interactive installers (e.g. Channels DVR Server) launch a long-running
                # application on completion that never exits, which would make waiting for it
                # block forever. Launch and move on instead of waiting; don't delete the
                # downloaded file since the process may still be reading it after we return.
                #
                # De-elevated via the fire-and-forget helper, not Start-WinUtilProcessAsStandardUser -
                # that one waits for an exit code, and its own fallback-to-elevated-on-timeout would
                # misfire here since not exiting is expected, not a failure. No process handle comes
                # back from that path, so Set-WinUtilProcessForeground (which needs one) only runs on
                # the elevated fallback - a minor, accepted UX tradeoff for launching de-elevated.
                if (Start-WinUtilProcessAsStandardUserNoWait -FilePath $dest) {
                    Write-WinUtilLog -Component "Package" -Message "$name installer launched - it may need you to finish a setup wizard. WinUtil will not wait for it to close."
                } else {
                    $proc = Start-Process -FilePath $dest -PassThru
                    Set-WinUtilProcessForeground -Process $proc
                    Write-WinUtilLog -Component "Package" -Message "$name installer launched - it may need you to finish a setup wizard. WinUtil will not wait for it to close."
                }
            } else {
                Start-WinUtilProcessAsStandardUser -FilePath $dest -ArgumentList @($installArgs) | Out-Null
                Write-WinUtilLog -Component "Package" -Message "$name installed."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to run installer for ${name}: $_"
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
    }
}
