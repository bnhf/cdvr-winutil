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
            # --exact matters here: without it, winget does fuzzy prefix matching and can
            # silently resolve to a different, unrelated package (e.g. "Google.Chrome" fuzzy-
            # matched "Google.Chrome.Beta.EXE" and reported its version info instead).
            $result = & winget list --id $WingetId --exact --accept-source-agreements --disable-interactivity 2>&1
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
