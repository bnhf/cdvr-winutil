#===========================================================================
# Tests - LAN IP detection (for Olivetin's CHANNELS_DVR value)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Get-WinUtilLanIPAddress.ps1")
}

Describe "Get-WinUtilLanIPAddress" {
    It "returns the IPv4 address of the default route's adapter" {
        Mock Get-NetRoute {
            @([pscustomobject]@{ InterfaceIndex = 5; NextHop = "192.168.1.1"; RouteMetric = 25 })
        }
        Mock Get-NetAdapter {
            [pscustomobject]@{ InterfaceIndex = 5; Status = "Up"; Virtual = $false }
        }
        Mock Get-NetIPAddress {
            [pscustomobject]@{ InterfaceIndex = 5; IPAddress = "192.168.1.50" }
        }

        Get-WinUtilLanIPAddress | Should -Be "192.168.1.50"
    }

    It "skips a lower-metric VPN's virtual adapter and falls through to the real LAN adapter" {
        # Regression guard: a VPN client's virtual adapter often installs a lower-metric default
        # route than the real LAN adapter, so picking purely by lowest RouteMetric (as a naive
        # "first default route" approach would) can return the VPN's own address instead of a
        # LAN-reachable one.
        Mock Get-NetRoute {
            @(
                [pscustomobject]@{ InterfaceIndex = 9; NextHop = "10.8.0.1"; RouteMetric = 1 }
                [pscustomobject]@{ InterfaceIndex = 5; NextHop = "192.168.1.1"; RouteMetric = 25 }
            )
        }
        Mock Get-NetAdapter {
            [pscustomobject]@{ InterfaceIndex = 9; Status = "Up"; Virtual = $true }
        } -ParameterFilter { $InterfaceIndex -eq 9 }
        Mock Get-NetAdapter {
            [pscustomobject]@{ InterfaceIndex = 5; Status = "Up"; Virtual = $false }
        } -ParameterFilter { $InterfaceIndex -eq 5 }
        Mock Get-NetIPAddress {
            [pscustomobject]@{ InterfaceIndex = 5; IPAddress = "192.168.1.50" }
        } -ParameterFilter { $InterfaceIndex -eq 5 }

        Get-WinUtilLanIPAddress | Should -Be "192.168.1.50"
    }

    It "excludes a link-local (APIPA) address" {
        Mock Get-NetRoute {
            @([pscustomobject]@{ InterfaceIndex = 5; NextHop = "192.168.1.1"; RouteMetric = 25 })
        }
        Mock Get-NetAdapter {
            [pscustomobject]@{ InterfaceIndex = 5; Status = "Up"; Virtual = $false }
        }
        Mock Get-NetIPAddress {
            [pscustomobject]@{ InterfaceIndex = 5; IPAddress = "169.254.1.2" }
        }

        Get-WinUtilLanIPAddress | Should -BeNullOrEmpty
    }

    It "returns `$null instead of throwing when no default route can be determined" {
        Mock Get-NetRoute { throw "no routes" }

        { Get-WinUtilLanIPAddress } | Should -Not -Throw
        Get-WinUtilLanIPAddress | Should -BeNullOrEmpty
    }

    It "returns `$null when every candidate adapter is virtual or down" {
        Mock Get-NetRoute {
            @([pscustomobject]@{ InterfaceIndex = 9; NextHop = "10.8.0.1"; RouteMetric = 1 })
        }
        Mock Get-NetAdapter {
            [pscustomobject]@{ InterfaceIndex = 9; Status = "Up"; Virtual = $true }
        }

        Get-WinUtilLanIPAddress | Should -BeNullOrEmpty
    }
}
