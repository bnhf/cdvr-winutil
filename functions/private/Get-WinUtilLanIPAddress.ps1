function Get-WinUtilLanIPAddress {
    <#
    .SYNOPSIS
        Returns the LAN IPv4 address of the network adapter that owns the machine's default
        route - the address other devices on the LAN would use to reach this machine - or
        $null if none could be confidently determined.

    .DESCRIPTION
        Finds the default-route (0.0.0.0/0) interface with the lowest route metric, the
        standard way to identify "the adapter Windows considers primary for general traffic" -
        but a VPN client's virtual adapter often installs an even lower-metric default route
        than the real LAN adapter, so candidates are filtered to non-virtual, connected
        adapters (excludes VPN TAP/TUN-style adapters, and Hyper-V/WSL/Docker's own virtual
        switches) before picking the lowest-metric match, rather than trusting metric ordering
        alone. Also excludes link-local (169.254.x.x/APIPA) addresses, which indicate a
        misconfigured or disconnected adapter, not a usable LAN address.

        Returns $null rather than throwing on any failure (no qualifying adapter, cmdlets
        unavailable, etc.) - callers should have a sensible fallback for "couldn't determine
        this" rather than treating it as fatal.
    #>
    try {
        $candidateRoutes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric

        foreach ($route in $candidateRoutes) {
            $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            if (-not $adapter -or $adapter.Status -ne 'Up' -or $adapter.Virtual) {
                continue
            }

            $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1

            if ($ip) {
                return $ip.IPAddress
            }
        }

        return $null
    } catch {
        return $null
    }
}
