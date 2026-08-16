Function Uninstall-WinUtilStreamLinkManager {
    <#
    .SYNOPSIS
        Uninstalls Streaming Library Manager.

    .DESCRIPTION
        No "uninstall" handle exists in slm.bat itself - only install/upgrade/startup/port - so
        this still has to reconstruct the removal steps directly rather than delegating to it.

        Author-confirmed gap in the previous version of this function: it never removed the
        Windows Firewall rule "port" creates. Fixed here by removing it by its fixed, known
        DisplayName ("Streaming Library Manager") via Remove-NetFirewallRule -DisplayName - the
        same NetSecurity module Invoke-WinUtilSSHServer.ps1 already uses elsewhere in this
        project. slm.bat's own "port" command creates the rule with raw netsh
        (name="Streaming Library Manager"), not this cmdlet, but netsh and the NetSecurity
        module both read/write the same underlying Windows Firewall rule store, so a
        netsh-created rule is fully visible to, and removable by, Remove-NetFirewallRule. Found
        by name regardless of which port was actually configured, since the rule's name never
        varies - only its LocalPort does. -DisplayName is used directly rather than looking it
        up with Get-NetFirewallRule first and piping the result in - Remove-NetFirewallRule's
        pipeline parameter is strictly typed to a real CimInstance, which doesn't accept a
        substitute object in a test double the way -DisplayName (a plain string parameter) does.

        Since Install-WinUtilStreamLinkManager owns the entire install location (a fixed folder
        under LocalAppData that only it writes to), this can safely remove it outright: stop the
        process, unregister the logon scheduled task, remove the firewall rule, remove the
        persisted SLM_PORT user environment variable, delete the install directory. Also removes
        "StreamLinkManager" (the previous, incorrectly-named install folder, before this was
        fixed to match the app's actual name) if still present, so upgrading past that old bug
        doesn't leave an orphaned copy of the app behind - this is the exact "leftover files
        after an uninstall" problem this project has been chasing elsewhere, self-inflicted here
        by an earlier version of this same function.

        Author-confirmed gap: SLM_PORT (set via slm.bat's own "port" command, using setx) used
        to survive uninstall entirely - setx has no built-in removal counterpart, so this has to
        be done directly. [Environment]::SetEnvironmentVariable(name, $null, "User") is the
        documented way to delete a persisted user environment variable via .NET (a $null value
        removes the registry value rather than setting it to an empty string).

        ProgressCallback works the same way as Install-WinUtilProgramDirect's - see that
        function's docstring for why it exists.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [scriptblock]$ProgressCallback
    )

    $taskName = "Streaming Library Manager"
    $firewallRuleName = "Streaming Library Manager"

    foreach ($package in $Packages) {
        $name = $package.content
        $installDir = Join-Path $env:LocalAppData "StreamingLibraryManager"
        $oldInstallDir = Join-Path $env:LocalAppData "StreamLinkManager"

        Write-WinUtilLog -Component "Package" -Message "Uninstalling $name"
        if ($ProgressCallback) { try { & $ProgressCallback "Uninstalling $name..." } catch {} }
        try {
            Get-Process -Name "slm" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            }

            Remove-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable("SLM_PORT", $null, "User")

            foreach ($dir in @($installDir, $oldInstallDir)) {
                if (Test-Path $dir) {
                    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            Write-WinUtilLog -Component "Package" -Message "$name uninstalled."
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "Failed to uninstall ${name}: $_"
        }
    }
}
