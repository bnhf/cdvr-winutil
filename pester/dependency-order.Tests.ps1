#===========================================================================
# Tests - Package install ordering by "requires"
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilPackagesInDependencyOrder.ps1")
}

Describe "Get-WinUtilPackagesInDependencyOrder" {
    It "orders a multi-level dependency chain correctly regardless of input order" {
        # Regression guard for a real report: Docker Desktop and Debian both install via winget
        # now (Debian moved off "wsl --install"), landing in the same bucket with no ordering
        # between them - Docker Desktop installed before Debian despite declaring it as a
        # requirement. This mirrors the real catalog chain: wsl2 -> debian -> dockerdesktop ->
        # olivetin.
        $wsl2 = [pscustomobject]@{ Key = "wsl2"; content = "WSL2" }
        $dockerdesktop = [pscustomobject]@{ Key = "dockerdesktop"; content = "Docker Desktop"; requires = @("wsl2", "debian") }
        $debian = [pscustomobject]@{ Key = "debian"; content = "Debian"; requires = @("wsl2") }
        $olivetin = [pscustomobject]@{ Key = "olivetin"; content = "Olivetin"; requires = @("wsl2", "debian", "dockerdesktop") }

        # Deliberately scrambled input order.
        $result = Get-WinUtilPackagesInDependencyOrder -Packages @($dockerdesktop, $olivetin, $wsl2, $debian)
        $order = @($result | ForEach-Object { $_.Key })

        $order.IndexOf("wsl2") | Should -BeLessThan $order.IndexOf("debian")
        $order.IndexOf("debian") | Should -BeLessThan $order.IndexOf("dockerdesktop")
        $order.IndexOf("dockerdesktop") | Should -BeLessThan $order.IndexOf("olivetin")
    }

    It "leaves packages with no dependency relationship in their original relative order" {
        $chrome = [pscustomobject]@{ Key = "chrome"; content = "Chrome" }
        $vlc = [pscustomobject]@{ Key = "vlc"; content = "VLC" }

        $result = Get-WinUtilPackagesInDependencyOrder -Packages @($vlc, $chrome)
        @($result | ForEach-Object { $_.Key }) | Should -Be @("vlc", "chrome")
    }

    It "does not crash on a package with no .Key" {
        $noKey = [pscustomobject]@{ content = "No Key Item" }
        $chrome = [pscustomobject]@{ Key = "chrome"; content = "Chrome" }

        { Get-WinUtilPackagesInDependencyOrder -Packages @($noKey, $chrome) } | Should -Not -Throw

        # Capture into a variable before wrapping in @() - see Get-WinUtilPackagesInDependencyOrder.ps1's
        # own docstring: @() around the CALL itself double-wraps its comma-prefixed return.
        $result = Get-WinUtilPackagesInDependencyOrder -Packages @($noKey, $chrome)
        @($result).Count | Should -Be 2
    }

    It "does not infinitely recurse on a dependency cycle" {
        # Should never happen from the real catalog, but this is a defensive guard, not an
        # assumption the catalog is trusted to enforce at runtime.
        $a = [pscustomobject]@{ Key = "a"; content = "A"; requires = @("b") }
        $b = [pscustomobject]@{ Key = "b"; content = "B"; requires = @("a") }

        { Get-WinUtilPackagesInDependencyOrder -Packages @($a, $b) } | Should -Not -Throw

        $result = Get-WinUtilPackagesInDependencyOrder -Packages @($a, $b)
        @($result).Count | Should -Be 2
    }

    It "returns an empty array, not `$null`, for an empty selection" {
        $result = Get-WinUtilPackagesInDependencyOrder -Packages @()
        ($null -eq $result) | Should -BeFalse
        @($result).Count | Should -Be 0
    }
}
