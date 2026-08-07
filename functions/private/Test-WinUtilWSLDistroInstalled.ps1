function Test-WinUtilWSLDistroInstalled {
    <#
    .SYNOPSIS
        Returns $true if the named WSL distro is already installed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro
    )

    try {
        $installed = & wsl -l -q 2>$null | ForEach-Object { $_.Trim().TrimEnd([char]0) } | Where-Object { $_ }
        return $installed -contains $Distro
    } catch {
        return $false
    }
}
