function Select-WinUtilGithubReleaseAsset {
    <#
    .SYNOPSIS
        Picks the right release asset from a GitHub release's asset list, when the pattern
        used to find it (e.g. "Clicker-Setup-*.exe") matches more than one - specifically,
        avoiding a Windows ARM64 build on ordinary x64 hardware.

    .DESCRIPTION
        Install-WinUtilProgramGithub's own matching used to be "first asset whose name matches
        the glob" - fine while a release only published one Windows installer, but confirmed
        live to silently grab the wrong one for Clicker (mackid1993/Clicker), whose release also
        publishes "Clicker-Setup-<version>-arm64.exe" alongside the plain x64
        "Clicker-Setup-<version>.exe" - both match "Clicker-Setup-*.exe", and GitHub's own
        release API happens to list the arm64 one first, so a user on ordinary x64 hardware got
        an installer that can't run there at all.

        Only changes behavior when the pattern actually matches more than one asset - a single
        match (still by far the common case for these catalog entries) is returned as-is,
        architecture-blind, exactly like before.

        When there's a choice, filtered by the CURRENT machine's real architecture via
        RuntimeInformation.OSArchitecture (not $env:PROCESSOR_ARCHITECTURE, which reports the
        32-bit WOW64 architecture instead of the host's when this process itself is 32-bit):
          - On x64/x86 hosts: never returns an arm64-tagged asset if a non-tagged one is also
            available - an arm64 Windows build simply won't launch on this hardware, whereas the
            reverse isn't true (an x64 build runs fine on ARM64 Windows via its built-in
            emulation), so the untagged asset is the only universally safe default.
          - On arm64 hosts: prefers the arm64-tagged asset (native, no emulation) if present,
            falling back to a non-tagged one otherwise - still better than failing outright.

        The arm64 tag is matched as a whole path segment ("-arm64", "_arm64", ".arm64", or
        "arm64" bounded by the string's own edges - same for "aarch64"), not a bare substring
        search, so a hypothetical asset name that merely contains "arm64" as part of something
        else (e.g. a hash or an unrelated word) isn't misclassified.

    .OUTPUTS
        The chosen asset object (same shape as GitHub's own release asset), or $null if
        -MatchingAssets was empty.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$MatchingAssets,

        # Overridable so Pester can exercise the arm64-host branch deterministically without
        # actually running on arm64 hardware - production callers never pass this and get the
        # real host architecture.
        [bool]$IsArm64Host = ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64)
    )

    $candidates = @($MatchingAssets)
    if ($candidates.Count -le 1) {
        return $candidates | Select-Object -First 1
    }

    $armPattern = '(?i)(^|[-_.])(arm64|aarch64)([-_.]|$)'

    $armAssets = @($candidates | Where-Object { $_.name -match $armPattern })
    $nonArmAssets = @($candidates | Where-Object { $_.name -notmatch $armPattern })

    if ($IsArm64Host -and $armAssets.Count -gt 0) {
        return $armAssets | Select-Object -First 1
    }
    if ($nonArmAssets.Count -gt 0) {
        return $nonArmAssets | Select-Object -First 1
    }

    # Only arm64-tagged assets exist at all (e.g. an arm64-only release) - nothing safer to fall
    # back to, so return the first match same as before this function existed.
    return $candidates | Select-Object -First 1
}
