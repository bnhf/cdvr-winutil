function Invoke-WinUtilWithTimeout {
    <#
    .SYNOPSIS
        Runs a scriptblock with a hard time limit, returning -DefaultValue instead of
        blocking indefinitely if it doesn't finish in time.

    .DESCRIPTION
        For wrapping external commands that can occasionally hang or run far longer than
        normal - e.g. wsl.exe attempting to reach the Microsoft Store on a system where WSL
        isn't installed yet (a well-documented real-world quirk, not hypothetical), or
        Get-WindowsOptionalFeature against a slow or corrupted DISM/CBS state. Several
        prerequisite checks that need this run synchronously on the UI thread (Resolve-
        WinUtilPrerequisites has to, to show its modal dialog), so a hang there froze the
        whole app rather than just delaying a background operation.

        Runs the scriptblock in its own throwaway runspace (not $sync.runspace's pool - this
        is for occasional single-shot calls, not frequent background work) so a timeout here
        doesn't block the caller. On timeout, the still-running PowerShell instance is cleaned
        up asynchronously in the background rather than torn down synchronously - forcibly
        stopping some cmdlets (DISM in particular) can itself hang.

    .PARAMETER ScriptBlock
        Runs in a separate runspace - it has no access to variables/functions from the caller
        (including $sync), only built-in cmdlets/external commands and whatever -ArgumentList
        supplies.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 8,

        $DefaultValue = $null
    )

    if (-not ("WinUtilTimeoutCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class WinUtilTimeoutCleanupState
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilTimeoutCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilTimeoutCleanupState;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
        }
    }
}
"@ -ErrorAction Stop
    }

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($ScriptBlock)
    foreach ($arg in $ArgumentList) {
        [void]$ps.AddArgument($arg)
    }
    $handle = $ps.BeginInvoke()

    if ($handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        try {
            $result = $ps.EndInvoke($handle)
            return $result
        } catch {
            return $DefaultValue
        } finally {
            $ps.Dispose()
        }
    }

    # Timed out - don't wait on or dispose it here (could itself hang); let it finish (or
    # not) in the background and get cleaned up once it does, via the thread pool.
    $cleanupState = [WinUtilTimeoutCleanupState]::new()
    $cleanupState.PowerShell = $ps
    $cleanupState.Handle = $handle
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject($handle.AsyncWaitHandle, [WinUtilTimeoutCleanup]::Callback, $cleanupState, -1, $true) | Out-Null
    return $DefaultValue
}
