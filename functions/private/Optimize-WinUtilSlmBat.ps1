function Optimize-WinUtilSlmBat {
    <#
    .SYNOPSIS
        Patches slm.bat's own download, extraction, and wait commands after it's downloaded but
        before it's run - faster, and safe to run non-interactively.

    .DESCRIPTION
        Three narrow, mechanical text substitutions on slm.bat's own downloaded file content -
        not a reimplementation of its download/extract/port logic, just changing how three of
        its own commands run, not what they do or produce. Plain String.Replace (literal
        substring matching), not the -replace operator, so neither the search text nor the
        replacement text needs regex escaping. If upstream ever changes any of this exact
        wording, that one substitution silently does nothing rather than breaking anything -
        slm.bat runs with its own (slower, or stdin-fragile) original command instead.

        Confirmed live: a single "slm.bat upgrade" run took over 5 minutes end to end, almost
        entirely in two of its own steps, both well-known PowerShell 5.1 anti-patterns already
        fixed elsewhere in this project's own code:
          - Its download step runs `Invoke-WebRequest -Uri '%link%' -OutFile '%outfile%'` with no
            $ProgressPreference set - Invoke-WebRequest's default live progress-bar rendering
            redraws on every buffer chunk and can slow a download by 10-100x, worst on Windows
            PowerShell 5.1 (which is what slm.bat invokes via plain "powershell").
          - Its extraction step runs `Expand-Archive`, well known to be dramatically slower than
            [System.IO.Compression.ZipFile]::ExtractToDirectory() for archives with many files -
            this release has around 3000. ExtractToDirectory's destination ('slm') is a relative
            path, matching Expand-Archive's own default (a folder named after the zip, in the
            current directory) - both processes inherit slm.bat's own working directory, fixed
            at the top of its script (cd /d "%~dp0") to the folder slm.bat itself runs from.

        Also confirmed live: `timeout /NOBREAK /T 5` - used throughout slm.bat to pace itself
        after starting a background/elevated step - hard-refuses to run at all when its stdin
        isn't a real console ("ERROR: Input redirection is not supported, exiting the process
        immediately"), which Install-WinUtilStreamLinkManager.ps1 needs to be for slm.bat's own
        "port" command, to feed its interactive `set /P` prompt a value non-interactively. Every
        occurrence is replaced with `ping -n 6 127.0.0.1 >nul` - the standard batch-scripting
        substitute for "wait 5 seconds" that doesn't touch stdin or need a console at all (six
        pings at the default one-second interval, the first sent immediately). Applied file-wide
        rather than only where it's currently needed, since any future caller redirecting stdin
        into any other slm.bat command would hit the exact same failure otherwise.

        Best-effort: failing to patch (or the text not matching) is logged and the caller
        proceeds with the unpatched file - a slower or more fragile install is not a reason to
        fail one outright.

    .OUTPUTS
        $true if the file was changed by at least one substitution, $false if none of the
        expected text was found, or reading/writing the file failed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $original = Get-Content -Path $Path -Raw

        $searchDownload = "Invoke-WebRequest -Uri '%link%' -OutFile '%outfile%'"
        $replaceDownload = '$ProgressPreference = ''SilentlyContinue''; Invoke-WebRequest -Uri ''%link%'' -OutFile ''%outfile%'''
        $searchExtract = "Expand-Archive -LiteralPath .\%outfile%"
        $replaceExtract = 'Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory(''%outfile%'', ''slm'')'
        $searchWait = "timeout /NOBREAK /T 5"
        $replaceWait = "ping -n 6 127.0.0.1 >nul"

        $patched = $original.Replace($searchDownload, $replaceDownload).Replace($searchExtract, $replaceExtract).Replace($searchWait, $replaceWait)

        if ($patched -eq $original) {
            Write-WinUtilLog -Level "WARN" -Component "Package" -Message "slm.bat's download/extract/wait commands didn't match the expected text - upstream may have changed it. Continuing with its own (slower, and possibly stdin-fragile) defaults."
            return $false
        }

        Set-Content -Path $Path -Value $patched -Encoding ASCII
        Write-WinUtilLog -Component "Package" -Message "Patched slm.bat: faster download/extract, and waits that work with a non-interactive stdin."
        return $true
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Could not patch slm.bat for speed/reliability - continuing with its own defaults: $_"
        return $false
    }
}
