Function Uninstall-WinUtilStreamLinkManager {
    <#
    .SYNOPSIS
        Uninstalls Streaming Library Manager.

    .DESCRIPTION
        No uninstall is documented upstream for slm.bat. Since Install-WinUtilStreamLinkManager
        owns the entire install location (a fixed folder under LocalAppData, not something the
        user chose or put other data into), this can safely remove it outright: stop the
        process, unregister the logon scheduled task, delete the install directory.

        ProgressCallback works the same way as Install-WinUtilProgramDirect's - see that
        function's docstring for why it exists.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    $taskName = "Streaming Library Manager"

    foreach ($package in $Packages) {
        $name = $package.content
        $installDir = Join-Path $env:LocalAppData "StreamLinkManager"

        Write-WinUtilLog -Component "Package" -Message "Uninstalling $name"
        if ($ProgressCallback) { try { & $ProgressCallback "Uninstalling $name..." } catch {} }
        try {
            Get-Process -Name "slm" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            & schtasks /delete /tn $taskName /f 2>$null | Out-Null

            if (Test-Path $installDir) {
                Remove-Item $installDir -Recurse -Force
            }

            Write-WinUtilLog -Component "Package" -Message "$name uninstalled."
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall ${name}: $_"
        }
    }
}
