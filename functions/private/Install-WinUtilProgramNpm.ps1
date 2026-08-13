Function Install-WinUtilProgramNpm {
    <#
    .SYNOPSIS
        Installs or uninstalls a global npm package. Requires Node.js/npm to already be on
        PATH - packages using this installType should declare "nodejs" in their "requires".

    .DESCRIPTION
        ProgressCallback works the same way as Install-WinUtilProgramDirect's - see that
        function's docstring for why it exists.

        Runs npm via "cmd.exe /c", not Start-Process -FilePath "npm" directly - confirmed live,
        the direct form fails with "%1 is not a valid Win32 application." The Node.js Windows
        installer's own "npm" is npm.cmd, a batch shim, not a real .exe; -NoNewWindow forces
        Start-Process's underlying ProcessStartInfo.UseShellExecute to $false, which performs a
        literal CreateProcess-style launch with no file-association resolution, so it tries to
        execute the batch file's raw bytes as a native binary instead of dispatching it through
        cmd.exe the way typing "npm ..." at a prompt would. This exact error was previously
        masked by an earlier PATH-detection bug (npm wasn't found on PATH at all, so this call
        was never reached) - fixing that surfaced this next, previously-unreachable failure.
    #>
    param (
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install",

        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    # Node.js (npm's own prerequisite) may have installed via winget/choco earlier in this same
    # run - refresh PATH so this process actually sees it instead of reporting a false negative.
    Update-WinUtilSessionPath

    foreach ($package in $Packages) {
        $name = $package.content
        $npmPackage = $package.npmPackage

        if ([string]::IsNullOrWhiteSpace($npmPackage)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm $($Action.ToLower()) for $name is missing npmPackage."
            continue
        }

        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "npm is not on PATH - can't $($Action.ToLower()) $name."
            continue
        }

        $npmVerb = if ($Action -eq "Uninstall") { "uninstall" } else { "install" }
        Write-WinUtilLog -Component "Package" -Message "$Action $name via npm ($npmPackage)"
        if ($ProgressCallback) { try { & $ProgressCallback "$Action $name via npm..." } catch {} }
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "npm", $npmVerb, "-g", $npmPackage) -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$name npm $($npmVerb) completed (exit code: $($process.ExitCode))"

        # Some npm-distributed tools need a separate step to actually start running (or set up
        # their own auto-start) after the package itself is installed - e.g. Prismcast installs
        # as a dormant CLI until "prismcast service install" registers and starts it as a
        # background service.
        if ($Action -eq "Install" -and $process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($package.postInstallCommand)) {
            Write-WinUtilLog -Component "Package" -Message "Running post-install step for $name`: $($package.postInstallCommand)"
            try {
                & ([scriptblock]::Create($package.postInstallCommand))
                Write-WinUtilLog -Component "Package" -Message "$name post-install step completed"
            } catch {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Post-install step failed for ${name}: $_"
            }
        }
    }
}
