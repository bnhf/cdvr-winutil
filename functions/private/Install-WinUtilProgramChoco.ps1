function Install-WinUtilProgramChoco {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    if ($Action -eq 'Install') {
        $arguments = "install $Programs -y"
    } else {
        $arguments = "uninstall $Programs -y"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -eq 0) {
        Write-WinUtilLog -Component "Package" -Message "$Action choco package(s) completed: $($Programs -join ', ')"
    } else {
        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action choco package(s) FAILED: $($Programs -join ', ') (exit code: $($process.ExitCode))"
    }
}
