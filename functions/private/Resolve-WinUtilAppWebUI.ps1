function Resolve-WinUtilAppWebUI {
    <#
    .SYNOPSIS
        Resolves an app's web UI URL for the popup's "Open" button, substituting the current
        value of a declared environment variable in place of the catalog's default port when
        the app's actual port can change after install.

    .DESCRIPTION
        Author-confirmed gap: Streaming Library Manager's "Open Web Interface" button was
        hardcoded to the catalog's declared default port (5000) even after SLM_PORT was set to
        something else during install - the popup always opened the wrong port. Only kicks in
        for a catalog entry that declares "webuiPortEnvVar" (currently just
        streamlinkmanager: "SLM_PORT") - every other app's "webui" is returned completely
        unchanged, matching the existing, pre-this-function behavior for the rest of the catalog.

        [Environment]::GetEnvironmentVariable(..., "User") rather than $env:<name> - the env var
        is set via setx (a registry write, read by NEW processes at their own startup), which
        WinUtil's own already-running process would never pick up into its own $env: snapshot
        without a restart; the .NET API reads the registry value directly instead, live.

        The port is found and replaced by matching ":<digits>" immediately before a "/" or the
        end of the string, not by parsing and rebuilding the URI with UriBuilder - UriBuilder
        normalizes a path-less URL by appending a trailing "/", which would turn an otherwise
        unrelated, cosmetic difference from the catalog's own plain "http://localhost:5000" (no
        trailing slash) into an apparent behavior change. If no explicit port is found to
        replace (e.g. the catalog's URL doesn't declare one at all), the original URL is
        returned unchanged rather than guessing where to insert one.

    .OUTPUTS
        The resolved URL string, or $null if the app has no "webui" declared at all.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$AppObject
    )

    if ([string]::IsNullOrWhiteSpace($AppObject.webui)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($AppObject.webuiPortEnvVar)) {
        return $AppObject.webui
    }

    $envPort = [Environment]::GetEnvironmentVariable($AppObject.webuiPortEnvVar, "User")
    if ([string]::IsNullOrWhiteSpace($envPort) -or $envPort -notmatch '^\d+$') {
        return $AppObject.webui
    }

    return [regex]::Replace($AppObject.webui, ':\d+(?=/|$)', ":$envPort")
}
