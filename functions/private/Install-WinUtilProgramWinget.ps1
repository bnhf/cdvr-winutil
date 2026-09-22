Function Install-WinUtilProgramWinget {
    <#
    .SYNOPSIS
        Installs or uninstalls the given winget package IDs.

    .DESCRIPTION
        Runs winget de-elevated (standard user) first via Start-WinUtilProcessAsStandardUser -
        the same context an ordinary, non-admin user runs winget in, and the context most
        per-user-scope packages (the majority of the catalog: browsers, Node.js, etc.) actually
        need to install/uninstall correctly. Only falls back to running winget natively in
        WinUtil's own elevated process when the de-elevated attempt fails for any reason -
        machine-scope packages (e.g. VLC, whose uninstaller needs admin rights to touch Program
        Files/HKLM) are expected to fail de-elevated and succeed on that elevated retry.

        This is the reverse of an earlier version of this function, which ran elevated first and
        only retried de-elevated on two specific "wrong integrity context" exit codes. That
        approach fixed the exit-code-reported failures (e.g. Vivaldi's uninstall) but missed a
        quieter class of the same problem: winget installing (or an installer auto-launching)
        entirely successfully while still elevated, which for a package like UniGetUI meant the
        app itself launched as Administrator and warned about it - not a failure winget reports
        via exit code at all, so no exit-code allowlist could have caught it. De-elevating first
        avoids that whole class of problem for every package that doesn't specifically need
        admin, rather than only reacting to the ones that fail loudly.

        Falling back on ANY non-zero exit code (not a curated list) is deliberate: the
        de-elevated attempt is now the one taking the risk (most packages should succeed there),
        so the fallback's job is just "make elevation available when something turns out to
        need it," the same permissive, catch-all fallback Start-WinUtilProcessAsStandardUser
        itself already uses when de-elevation can't be set up at all. The cost is a slower
        failure report for a genuine (non-scope-related) error, since it gets attempted twice
        before being reported - not a correctness issue, since the final reported result always
        reflects the elevated (fallback) attempt's own outcome.

    .OUTPUTS
        One [pscustomobject] per attempted program (blank/na entries are skipped, not
        included), each with .Program, .Success, and .ExitCode - so callers can report real
        per-item outcomes instead of assuming every attempt succeeded.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    $results = [System.Collections.Generic.List[object]]::new()

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

        $process = Start-WinUtilProcessAsStandardUser -FilePath winget -ArgumentList $arguments

        if ($process.ExitCode -ne 0) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "$Action winget package: $program failed running as standard user (exit code: $($process.ExitCode)) - retrying elevated."
            $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        }

        $success = $process.ExitCode -eq 0
        if ($success) {
            Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program"
        } else {
            $hint = if ($Action -eq 'Uninstall') {
                " If this keeps happening, try uninstalling it via Windows Settings > Apps instead."
            } else {
                ""
            }
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action winget package FAILED: $program (exit code: $($process.ExitCode)).$hint"
        }

        $results.Add([pscustomobject]@{ Program = $program; Success = $success; ExitCode = $process.ExitCode })
    }

    return ,$results.ToArray()
}
