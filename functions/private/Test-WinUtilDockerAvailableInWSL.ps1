function Test-WinUtilDockerAvailableInWSL {
    <#
    .SYNOPSIS
        Checks whether the "docker" CLI is actually reachable and working inside a given WSL
        distro - not just that Docker Desktop itself is installed.

    .DESCRIPTION
        Resolve-WinUtilPrerequisites already confirms Docker Desktop is installed before letting
        anything that "requires" it proceed, but installing the app doesn't automatically enable
        WSL integration for any particular distro - that's a separate, manual toggle in Docker
        Desktop's own Settings > Resources > WSL Integration, easy to miss. Without it, the
        "docker" command simply doesn't exist inside that distro at all - confirmed live: an
        Olivetin install failed with "docker: command not found" deep inside its own install
        script, with nothing pointing at the actual cause or fix.

        Distinguishes two different failure modes with two different fixes, rather than one
        generic "docker isn't available" message:
          - The "docker" command itself isn't on PATH in the distro - WSL integration isn't
            enabled for it.
          - "docker" exists but can't reach the daemon - Docker Desktop isn't running, or is
            still starting up.

        Bounded via Invoke-WinUtilWithTimeout, matching every other wsl.exe call in this app -
        the same class of hang risk applies here as anywhere else that shells out to wsl.exe.

    .OUTPUTS
        A [pscustomobject] with .Available ($true/$false) and .Reason - a specific, actionable
        message when .Available is $false, or $null when it's $true.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    $cliPresent = Invoke-WinUtilWithTimeout -TimeoutSeconds 15 -DefaultValue $false -ArgumentList @($Distro) -ScriptBlock {
        param($Distro)
        try {
            & wsl -d $Distro -- bash -c "command -v docker" 2>&1 | Out-Null
            return $LASTEXITCODE -eq 0
        } catch {
            return $false
        }
    }

    if (-not $cliPresent) {
        return [pscustomobject]@{
            Available = $false
            Reason = "The 'docker' command isn't available inside the $Distro WSL distro. In Docker Desktop, go to Settings > Resources > WSL Integration and enable integration for '$Distro', then try again."
        }
    }

    $daemonReachable = Invoke-WinUtilWithTimeout -TimeoutSeconds 15 -DefaultValue $false -ArgumentList @($Distro) -ScriptBlock {
        param($Distro)
        try {
            & wsl -d $Distro -- docker info 2>&1 | Out-Null
            return $LASTEXITCODE -eq 0
        } catch {
            return $false
        }
    }

    if (-not $daemonReachable) {
        return [pscustomobject]@{
            Available = $false
            Reason = "The 'docker' command is available inside $Distro, but can't reach the Docker daemon. Make sure Docker Desktop is running and has finished starting, then try again."
        }
    }

    return [pscustomobject]@{ Available = $true; Reason = $null }
}
