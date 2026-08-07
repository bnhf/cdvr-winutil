function Test-WinUtilProgramInstalled {
    <#
    .SYNOPSIS
        Returns $true if a winget or choco package ID is already installed. Used for
        prerequisite checks (e.g. is Docker Desktop / Node.js already present).
    #>
    param(
        [string]$WingetId,
        [string]$ChocoId
    )

    if (-not [string]::IsNullOrWhiteSpace($WingetId) -and $WingetId -ne "na") {
        try {
            $result = & winget list --id $WingetId --accept-source-agreements --disable-interactivity 2>&1
            if ($LASTEXITCODE -eq 0 -and (($result -join "`n") -match [regex]::Escape($WingetId))) {
                return $true
            }
        } catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($ChocoId) -and $ChocoId -ne "na") {
        try {
            $result = & choco list --local-only $ChocoId 2>&1
            if ($LASTEXITCODE -eq 0 -and (($result -join "`n") -match [regex]::Escape($ChocoId))) {
                return $true
            }
        } catch {}
    }

    return $false
}
