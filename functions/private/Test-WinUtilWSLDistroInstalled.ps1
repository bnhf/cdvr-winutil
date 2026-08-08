function Test-WinUtilWSLDistroInstalled {
    <#
    .SYNOPSIS
        Returns $true if the named WSL distro is already installed.

    .DESCRIPTION
        Bounded to a few seconds via Invoke-WinUtilWithTimeout - wsl.exe exists as a stub even
        before WSL is installed, and running it in that state can attempt to reach the
        Microsoft Store to auto-bootstrap, which can hang for a long time on a slow/absent
        network connection. Several callers of this run synchronously on the UI thread
        (Resolve-WinUtilPrerequisites has to, to show its modal dialog), so a hang here froze
        the whole app rather than just delaying a background operation.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    Invoke-WinUtilWithTimeout -TimeoutSeconds 8 -DefaultValue $false -ArgumentList @($Distro) -ScriptBlock {
        param($Distro)
        try {
            $installed = & wsl -l -q 2>$null | ForEach-Object { $_.Trim().TrimEnd([char]0) } | Where-Object { $_ }
            return $installed -contains $Distro
        } catch {
            return $false
        }
    }
}
