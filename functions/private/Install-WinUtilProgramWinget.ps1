Function Install-WinUtilProgramWinget {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $source = "winget"
        if ($program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        if ($Action -eq 'Install') {
            $arguments = @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent")
        } else {
            $arguments = @("uninstall", "--id", $program, "--source", $source, "--silent")
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"
        # Run winget as the standard (non-elevated) user, not as WinUtil's own elevated
        # process - winget refuses to manage per-user-scope packages while elevated
        # ("The package installed for user scope cannot be uninstalled when running with
        # administrator privileges."), and most winget packages install in user scope.
        $process = Start-WinUtilProcessAsStandardUser -FilePath winget -ArgumentList $arguments
        if ($process.ExitCode -eq 0) {
            Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program"
        } else {
            $hint = if ($Action -eq 'Uninstall') {
                " This commonly happens when winget can't manage a package that was installed in per-user scope while WinUtil is running elevated - if so, uninstall it via Windows Settings > Apps instead."
            } else {
                ""
            }
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action winget package FAILED: $program (exit code: $($process.ExitCode)).$hint"
        }
    }
}
