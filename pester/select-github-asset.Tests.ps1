#===========================================================================
# Tests - Select-WinUtilGithubReleaseAsset (architecture-aware GitHub asset picking)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Select-WinUtilGithubReleaseAsset.ps1")

    function script:New-WinUtilAsset([string]$Name) {
        [pscustomobject]@{ name = $Name; browser_download_url = "https://example.com/$Name" }
    }
}

Describe "Select-WinUtilGithubReleaseAsset" {
    It "returns the only match as-is, architecture-blind, when the pattern matches just one asset" {
        $asset = New-WinUtilAsset "Clicker-Setup-1.3.1-arm64.exe"

        $result = Select-WinUtilGithubReleaseAsset -MatchingAssets @($asset) -IsArm64Host $false

        $result.name | Should -Be "Clicker-Setup-1.3.1-arm64.exe"
    }

    It "returns null when there are no matches at all" {
        $result = Select-WinUtilGithubReleaseAsset -MatchingAssets @() -IsArm64Host $false

        $result | Should -BeNullOrEmpty
    }

    It "prefers the non-arm64 asset on an x64 host, regardless of listing order" {
        # Regression guard for the actual reported bug: Clicker's release lists
        # "Clicker-Setup-<version>-arm64.exe" before the plain x64 build (confirmed live against
        # the real repo) - an arm64 Windows build can't run on ordinary x64 hardware at all.
        $armFirst = @(New-WinUtilAsset "Clicker-Setup-1.3.1-arm64.exe"; New-WinUtilAsset "Clicker-Setup-1.3.1.exe")
        $x64First = @(New-WinUtilAsset "Clicker-Setup-1.3.1.exe"; New-WinUtilAsset "Clicker-Setup-1.3.1-arm64.exe")

        (Select-WinUtilGithubReleaseAsset -MatchingAssets $armFirst -IsArm64Host $false).name | Should -Be "Clicker-Setup-1.3.1.exe"
        (Select-WinUtilGithubReleaseAsset -MatchingAssets $x64First -IsArm64Host $false).name | Should -Be "Clicker-Setup-1.3.1.exe"
    }

    It "prefers the arm64 asset on an arm64 host" {
        # An x64 build still runs fine on Windows on ARM via its built-in emulation, but the
        # native arm64 build is the better choice when it's actually available.
        $assets = @(New-WinUtilAsset "Clicker-Setup-1.3.1.exe"; New-WinUtilAsset "Clicker-Setup-1.3.1-arm64.exe")

        $result = Select-WinUtilGithubReleaseAsset -MatchingAssets $assets -IsArm64Host $true

        $result.name | Should -Be "Clicker-Setup-1.3.1-arm64.exe"
    }

    It "falls back to the arm64-only asset on an x64 host when nothing else matches" {
        # Nothing safer to fall back to than the only asset that exists - same as returning the
        # single match above, just reached via the multi-match path.
        $assets = @(New-WinUtilAsset "Clicker-Setup-1.3.1-arm64.exe")

        $result = Select-WinUtilGithubReleaseAsset -MatchingAssets $assets -IsArm64Host $false

        $result.name | Should -Be "Clicker-Setup-1.3.1-arm64.exe"
    }

    It "does not misclassify an asset whose name merely contains 'arm' as part of another word" {
        $assets = @(New-WinUtilAsset "Charmless-Setup-1.0.0.exe"; New-WinUtilAsset "Charmless-Setup-1.0.0-arm64.exe")

        $result = Select-WinUtilGithubReleaseAsset -MatchingAssets $assets -IsArm64Host $false

        $result.name | Should -Be "Charmless-Setup-1.0.0.exe"
    }

    It "matches aarch64 the same way as arm64" {
        $assets = @(New-WinUtilAsset "app-x86_64.tar.gz"; New-WinUtilAsset "app-aarch64.tar.gz")

        (Select-WinUtilGithubReleaseAsset -MatchingAssets $assets -IsArm64Host $false).name | Should -Be "app-x86_64.tar.gz"
        (Select-WinUtilGithubReleaseAsset -MatchingAssets $assets -IsArm64Host $true).name | Should -Be "app-aarch64.tar.gz"
    }

    It "defaults -IsArm64Host to the real host architecture when not supplied" {
        # Sanity check that the parameter default actually wires up to RuntimeInformation rather
        # than silently requiring every caller to pass it - Install-WinUtilProgramGithub.ps1
        # never passes it.
        $expected = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
        $assets = @(New-WinUtilAsset "Clicker-Setup-1.3.1.exe"; New-WinUtilAsset "Clicker-Setup-1.3.1-arm64.exe")

        $result = Select-WinUtilGithubReleaseAsset -MatchingAssets $assets

        if ($expected) {
            $result.name | Should -Be "Clicker-Setup-1.3.1-arm64.exe"
        } else {
            $result.name | Should -Be "Clicker-Setup-1.3.1.exe"
        }
    }
}
