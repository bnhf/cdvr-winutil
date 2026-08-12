function Test-WinUtilWebUIReachable {
    <#
    .SYNOPSIS
        Returns $true if a webui URL's host:port accepts a TCP connection - used as an "is this
        installed" signal by "Show Installed Apps" for packages with no winget/choco/WSL-based
        detection (installType "direct"/"github", e.g. Channels DVR Server), since the catalog
        already carries this URL for the app's own "Open" button and most of these are always-on
        local server apps once installed.

    .DESCRIPTION
        Checks raw TCP connectivity rather than making a real HTTP request - a non-200 response
        (auth required, redirect, self-signed cert, non-root path, ...) still proves the server
        is up, and a plain socket connect avoids all of that without needing to interpret HTTP
        semantics at all. Bounded to 1.5s so a single unreachable app can't noticeably slow down
        "Show Installed Apps" scanning through the whole catalog.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $uri = [uri]$Url
        $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq 'https') { 443 } else { 80 }

        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $connectTask = $client.ConnectAsync($uri.Host, $port)
            if (-not $connectTask.Wait(1500)) {
                return $false
            }
            return $client.Connected
        } finally {
            $client.Dispose()
        }
    } catch {
        return $false
    }
}
