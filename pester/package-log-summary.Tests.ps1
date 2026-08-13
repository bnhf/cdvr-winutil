#===========================================================================
# Tests - Get-WinUtilPackageLogSummary
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPackageLogSummary.ps1")
}

Describe "Get-WinUtilPackageLogSummary" {
    It "uses the catalog's real display-name field (content), not description" {
        # Regression guard for a real production bug: confirmed live, every install/uninstall
        # summary log line showed the app's full description instead of its name (e.g. "Native
        # Win32 client for Channels DVR written in Rust with WinUI3 styling, by mackid1993
        # (formerly RustDVR). Not affiliated or endorsed by Fancy Bits LLC." instead of
        # "Clicker") - config/applications.json entries only ever have "content", never "Name",
        # so checking "Name" first and falling through to "Description" always picked the
        # description, for every app, not just ones missing a winget/choco id.
        $package = [pscustomobject]@{
            content     = "Clicker"
            description = "Native Win32 client for Channels DVR written in Rust with WinUI3 styling, by mackid1993."
        }

        $result = Get-WinUtilPackageLogSummary -Packages @($package) -Preference "Winget"

        $result | Should -Be @("Clicker (no package id)")
    }

    It "includes the winget id when present" {
        $package = [pscustomobject]@{ content = "Git"; winget = "Git.Git" }

        $result = Get-WinUtilPackageLogSummary -Packages @($package) -Preference "Winget"

        $result | Should -Be @("Git (winget: Git.Git)")
    }

    It "includes the choco id when the preference is Choco and a choco id is present" {
        $package = [pscustomobject]@{ content = "Git"; winget = "Git.Git"; choco = "git" }

        $result = Get-WinUtilPackageLogSummary -Packages @($package) -Preference "Choco"

        $result | Should -Be @("Git (choco: git)")
    }

    It "falls back to description only when content is genuinely absent" {
        $package = [pscustomobject]@{ description = "Some fallback description" }

        $result = Get-WinUtilPackageLogSummary -Packages @($package) -Preference "Winget"

        $result | Should -Be @("Some fallback description (no package id)")
    }

    It "falls back to 'Unknown package' when nothing identifying is present" {
        $package = [pscustomobject]@{ winget = "na"; choco = "na" }

        $result = Get-WinUtilPackageLogSummary -Packages @($package) -Preference "Winget"

        $result | Should -Be @("Unknown package (no package id)")
    }
}
