function Update-WinUtilSessionPath {
    <#
    .SYNOPSIS
        Refreshes $env:Path for the current process from the registry (Machine + User).

    .DESCRIPTION
        $env:Path is only populated once, at process start - it does not pick up changes an
        installer makes to the persisted PATH afterward. Confirmed live: installing Node.js via
        winget, then immediately installing an npm-type package (e.g. Prismcast) in the same
        install run, failed with "npm is not on PATH" even though the winget install had just
        completed successfully - npm.exe was on disk and the registry PATH was updated, but this
        already-running process never re-read it. Chocolatey's own install script sidesteps this
        for itself by appending directly to $env:Path during install, but winget does not, and a
        general-purpose fix here covers any installer regardless of how it updates PATH.
    #>
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath) -join ";"
}
