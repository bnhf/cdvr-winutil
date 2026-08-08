function Get-WinUtilSelectedPackages {

     param(
         [Parameter(Mandatory = $true)]
         [object] $PackageList,

         [Parameter(Mandatory = $true)]
         [string] $Preference
     )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packagesDirect = [System.Collections.ArrayList]::new()
    $packagesGithub = [System.Collections.ArrayList]::new()
    $packagesNpm = [System.Collections.ArrayList]::new()
    $packagesWslFeature = [System.Collections.ArrayList]::new()
    $packagesWslDistro = [System.Collections.ArrayList]::new()
    $packagesWslCommand = [System.Collections.ArrayList]::new()
    $packagesStreamLinkManager = [System.Collections.ArrayList]::new()
    $packages = @{
        Winget = $packagesWinget
        Choco = $packagesChoco
        Direct = $packagesDirect
        Github = $packagesGithub
        Npm = $packagesNpm
        WslFeature = $packagesWslFeature
        WslDistro = $packagesWslDistro
        WslCommand = $packagesWslCommand
        StreamLinkManager = $packagesStreamLinkManager
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId
        )

        if ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na") {
            return
        }

        if (-not $Target.Contains($PackageId)) {
            $null = $Target.Add($PackageId)
        }
    }

    foreach ($package in $PackageList) {
        $installType = [string]$package.installType

        # Packages with a custom installType bypass the winget/choco preference entirely -
        # they carry their own install data (url, repo, npmPackage, distro, command, ...).
        if (-not [string]::IsNullOrWhiteSpace($installType)) {
            switch ($installType) {
                "direct" { $null = $packagesDirect.Add($package) }
                "github" { $null = $packagesGithub.Add($package) }
                "npm" { $null = $packagesNpm.Add($package) }
                "wslFeature" { $null = $packagesWslFeature.Add($package) }
                "wslDistro" { $null = $packagesWslDistro.Add($package) }
                "wslCommand" { $null = $packagesWslCommand.Add($package) }
                "streamLinkManager" { $null = $packagesStreamLinkManager.Add($package) }
            }
            continue
        }

        switch ($Preference) {
            "Choco" {
                if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget
                } else {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco
                }
            }
            "Winget" {
                Add-PackageId -Target $packagesWinget -PackageId $package.winget
            }
        }
    }

    return $packages
}
