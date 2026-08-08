function Start-WinUtilProcessAsStandardUser {
    <#
    .SYNOPSIS
        Launches a process at the user's normal (non-elevated) integrity level from within
        WinUtil's elevated process - for operations like winget that behave incorrectly (or
        refuse outright) when run as Administrator against per-user-scope packages.

    .DESCRIPTION
        Uses the "linked token" technique: when UAC elevation happens, Windows creates a
        filtered "linked" standard-user token alongside the elevated one for the same logon
        session. This retrieves that linked token and uses CreateProcessWithTokenW to launch
        the target process with it, giving a real process handle/PID to wait on and read
        ExitCode from - unlike the more commonly-referenced Explorer/Shell.Application COM
        de-elevation trick, which doesn't hand back a usable process handle.

        Falls back to running the process normally (at the current, elevated, integrity) if
        any step fails - this is a best-effort correctness improvement, not something that
        should ever hard-fail an install/uninstall.

    .OUTPUTS
        A System.Diagnostics.Process for the launched process (already exited, WaitForExit
        already called) so callers can read .ExitCode the same way they would with
        Start-Process -PassThru -Wait.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @()
    )

    if (-not ([System.Management.Automation.PSTypeName]'WinUtil.StandardUserProcessNative').Type) {
        Add-Type -Namespace WinUtil -Name StandardUserProcessNative -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct STARTUPINFO {
    public int cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public int dwX;
    public int dwY;
    public int dwXSize;
    public int dwYSize;
    public int dwXCountChars;
    public int dwYCountChars;
    public int dwFillAttribute;
    public int dwFlags;
    public short wShowWindow;
    public short cbReserved2;
    public IntPtr lpReserved2;
    public IntPtr hStdInput;
    public IntPtr hStdOutput;
    public IntPtr hStdError;
}

[StructLayout(LayoutKind.Sequential)]
public struct PROCESS_INFORMATION {
    public IntPtr hProcess;
    public IntPtr hThread;
    public int dwProcessId;
    public int dwThreadId;
}

[StructLayout(LayoutKind.Sequential)]
public struct LUID {
    public uint LowPart;
    public int HighPart;
}

[StructLayout(LayoutKind.Sequential)]
public struct LUID_AND_ATTRIBUTES {
    public LUID Luid;
    public uint Attributes;
}

[StructLayout(LayoutKind.Sequential)]
public struct TOKEN_PRIVILEGES {
    public uint PrivilegeCount;
    public LUID_AND_ATTRIBUTES Privileges;
}

[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetCurrentProcess();

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool LookupPrivilegeValueW(string lpSystemName, string lpName, out LUID lpLuid);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool CreateProcessWithTokenW(IntPtr hToken, uint dwLogonFlags, string lpApplicationName, string lpCommandLine, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);
'@ -ErrorAction Stop
    }

    $TOKEN_QUERY = 0x0008
    $TOKEN_ADJUST_PRIVILEGES = 0x0020
    $TokenElevationType = 18
    $TokenLinkedToken = 19
    $TokenElevationTypeFull = 2
    $SE_PRIVILEGE_ENABLED = 0x00000002
    $LOGON_WITH_PROFILE = 0x00000001
    $CREATE_UNICODE_ENVIRONMENT = 0x00000400

    $quotedArgs = ($ArgumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $commandLine = "`"$FilePath`" $quotedArgs"

    $currentTokenHandle = [IntPtr]::Zero
    $linkedTokenHandle = [IntPtr]::Zero
    $elevationTypeBuffer = [IntPtr]::Zero
    $linkedTokenBuffer = [IntPtr]::Zero

    try {
        if (-not [WinUtil.StandardUserProcessNative]::OpenProcessToken([WinUtil.StandardUserProcessNative]::GetCurrentProcess(), $TOKEN_QUERY -bor $TOKEN_ADJUST_PRIVILEGES, [ref]$currentTokenHandle)) {
            throw "OpenProcessToken failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }

        $elevationTypeBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        $returnLength = 0
        if (-not [WinUtil.StandardUserProcessNative]::GetTokenInformation($currentTokenHandle, $TokenElevationType, $elevationTypeBuffer, 4, [ref]$returnLength)) {
            throw "GetTokenInformation(TokenElevationType) failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
        $elevationType = [Runtime.InteropServices.Marshal]::ReadInt32($elevationTypeBuffer)
        if ($elevationType -ne $TokenElevationTypeFull) {
            throw "Not running a full elevated (UAC split) token - nothing to de-elevate from (elevationType=$elevationType)"
        }

        $linkedTokenBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
        if (-not [WinUtil.StandardUserProcessNative]::GetTokenInformation($currentTokenHandle, $TokenLinkedToken, $linkedTokenBuffer, [IntPtr]::Size, [ref]$returnLength)) {
            throw "GetTokenInformation(TokenLinkedToken) failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
        $linkedTokenHandle = [Runtime.InteropServices.Marshal]::ReadIntPtr($linkedTokenBuffer)

        $luid = New-Object WinUtil.StandardUserProcessNative+LUID
        if (-not [WinUtil.StandardUserProcessNative]::LookupPrivilegeValueW($null, "SeImpersonatePrivilege", [ref]$luid)) {
            throw "LookupPrivilegeValueW failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
        $privileges = New-Object WinUtil.StandardUserProcessNative+TOKEN_PRIVILEGES
        $privileges.PrivilegeCount = 1
        $privileges.Privileges = New-Object WinUtil.StandardUserProcessNative+LUID_AND_ATTRIBUTES
        $privileges.Privileges.Luid = $luid
        $privileges.Privileges.Attributes = $SE_PRIVILEGE_ENABLED
        if (-not [WinUtil.StandardUserProcessNative]::AdjustTokenPrivileges($currentTokenHandle, $false, [ref]$privileges, 0, [IntPtr]::Zero, [IntPtr]::Zero)) {
            throw "AdjustTokenPrivileges(SeImpersonatePrivilege) failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }

        $startupInfo = New-Object WinUtil.StandardUserProcessNative+STARTUPINFO
        $startupInfo.cb = [Runtime.InteropServices.Marshal]::SizeOf([type]"WinUtil.StandardUserProcessNative+STARTUPINFO")
        $processInfo = New-Object WinUtil.StandardUserProcessNative+PROCESS_INFORMATION

        $workingDir = Split-Path -Path $FilePath -Parent
        if ([string]::IsNullOrWhiteSpace($workingDir)) { $workingDir = $env:TEMP }

        $created = [WinUtil.StandardUserProcessNative]::CreateProcessWithTokenW(
            $linkedTokenHandle, $LOGON_WITH_PROFILE, $null, $commandLine,
            $CREATE_UNICODE_ENVIRONMENT, [IntPtr]::Zero, $workingDir, [ref]$startupInfo, [ref]$processInfo)

        if (-not $created) {
            throw "CreateProcessWithTokenW failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }

        [void][WinUtil.StandardUserProcessNative]::CloseHandle($processInfo.hThread)
        [void][WinUtil.StandardUserProcessNative]::CloseHandle($processInfo.hProcess)

        $proc = [System.Diagnostics.Process]::GetProcessById($processInfo.dwProcessId)
        $proc.WaitForExit()
        return $proc
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Package" -Message "Could not run $FilePath as standard user, running elevated instead: $_"
        return Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru
    } finally {
        foreach ($ptr in @($elevationTypeBuffer, $linkedTokenBuffer)) {
            if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
        }
        if ($currentTokenHandle -ne [IntPtr]::Zero) { [void][WinUtil.StandardUserProcessNative]::CloseHandle($currentTokenHandle) }
        if ($linkedTokenHandle -ne [IntPtr]::Zero) { [void][WinUtil.StandardUserProcessNative]::CloseHandle($linkedTokenHandle) }
    }
}
