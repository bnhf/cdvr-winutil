#===========================================================================
# Tests - WSL2 / WSL distro uninstall
#===========================================================================

BeforeAll {
    Add-Type -AssemblyName PresentationFramework

    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilWithTimeout.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilWSLDistro.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilFeatureWSL.ps1")

    function wsl {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    }
    # Deliberately as strict as Write-WinUtilLog.ps1 was BEFORE it gained [AllowEmptyString()] -
    # Mandatory with no AllowEmptyString means PowerShell itself rejects an empty-string
    # -Message at the parameter-binding level, regardless of what's inside the function body.
    # Using that stricter shape here (rather than mirroring today's more lenient real function)
    # means these tests independently verify the WSL call sites never pass a bare, untouched
    # empty $output.Trim() straight to -Message - the actual real-world crash - rather than only
    # relying on Write-WinUtilLog's own leniency to paper over a call-site regression.
    function Write-WinUtilLog {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,

            [string]$Level = "INFO",

            [string]$Component = "WinUtil"
        )
    }
    function Test-WinUtilWSLDistroInstalled { param($Distro) $true }
    function Show-WinUtilMessage { param($Message, $Title, $Button, $Icon) }
    function Invoke-WPFUIThreadWithResult { param($ScriptBlock) }
}

Describe "Uninstall-WinUtilWSLDistro" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock wsl { $global:LASTEXITCODE = 0 }
        # Runs the real scriptblock inline (splatting ArgumentList through) instead of the real
        # isolated runspace, so the "wsl" mock above stays reachable - matches the pattern used
        # for Invoke-WinUtilWithTimeout throughout the rest of this suite.
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock @ArgumentList }
    }

    It "terminates and unregisters a distro that is currently registered" {
        Mock Test-WinUtilWSLDistroInstalled { $true }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        Uninstall-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--terminate Debian" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--unregister Debian" }
    }

    It "does nothing for a distro that isn't registered" {
        # Regression guard: unregistering permanently deletes the distro's filesystem - must
        # not attempt it against a distro that was never installed in the first place.
        Mock Test-WinUtilWSLDistroInstalled { $false }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        Uninstall-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly
    }

    It "logs an error and skips a package missing a distro name" {
        $package = [pscustomobject]@{ content = "Bad Entry"; distro = "" }
        Uninstall-WinUtilWSLDistro -Packages @($package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "ERROR" }
    }

    It "logs a placeholder instead of crashing when wsl --unregister produces no console output" {
        # Regression guard for a real production crash: "wsl --unregister" (and the other wsl.exe
        # calls throughout the WSL install/uninstall functions) can complete with empty
        # stdout/stderr, and Write-WinUtilLog's -Message is Mandatory - passing that empty string
        # straight through used to throw "Cannot bind argument ... because it is an empty
        # string", which then got caught and misreported as "failed to uninstall", masking
        # whatever the command's real result was.
        # Stateful: true on the first check (still registered, so the unregister attempt
        # proceeds), false afterward (confirms it actually got removed) - matches what the
        # function itself checks before and after the unregister attempt.
        $script:distroStillRegistered = $true
        Mock Test-WinUtilWSLDistroInstalled {
            $result = $script:distroStillRegistered
            $script:distroStillRegistered = $false
            $result
        }
        Mock wsl { $global:LASTEXITCODE = 0; "" }

        $package = [pscustomobject]@{ content = "Debian (WSL)"; distro = "Debian" }
        { Uninstall-WinUtilWSLDistro -Packages @($package) } | Should -Not -Throw

        Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter { $Level -eq "ERROR" }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -like "*no console output*" }

        Remove-Variable -Name distroStillRegistered -Scope Script -ErrorAction SilentlyContinue
    }
}

Describe "Uninstall-WinUtilFeatureWSL" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            configs = [pscustomobject]@{
                applicationsHashtable = @{
                    WPFInstallwsl2 = [pscustomobject]@{ content = "WSL2"; installType = "wslFeature" }
                    WPFInstalldebian = [pscustomobject]@{ content = "Debian (WSL)"; installType = "wslDistro"; distro = "Debian" }
                    WPFInstallchrome = [pscustomobject]@{ content = "Chrome"; winget = "Google.Chrome.EXE" }
                }
            }
        })
        Mock Write-WinUtilLog { }
        Mock wsl { $global:LASTEXITCODE = 0 }
        Mock Test-WinUtilWSLDistroInstalled { $true }
        # Invoke-WPFUIThreadWithResult normally marshals to the UI thread's Dispatcher - here it just runs
        # the scriptblock inline and returns its result, exercising the real confirm/decline
        # logic through Show-WinUtilMessage exactly as Uninstall-WinUtilFeatureWSL calls it.
        Mock Invoke-WPFUIThreadWithResult { & $ScriptBlock }
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock @ArgumentList }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
    }

    It "asks for confirmation, and unregisters the catalog's own WSL distro(s) when approved" {
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }

        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName Show-WinUtilMessage -Times 1 -Exactly -ParameterFilter {
            $Title -eq "Confirm WSL distro deletion" -and $Button -eq ([System.Windows.MessageBoxButton]::YesNo)
        }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--unregister Debian" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--shutdown" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--uninstall" }
    }

    It "does not delete the distro when the user declines, but still uninstalls the WSL2 runtime" {
        # Regression guard for the actual request: Debian must not be silently deleted as an
        # implicit side effect of uninstalling WSL2 - explicit approval is required, and
        # declining must not block the WSL2 runtime uninstall itself.
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::No }

        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly -ParameterFilter { ($Arguments -join " ") -like "*unregister*" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--uninstall" }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "Skipping deletion of Debian (WSL)*"
        }
    }

    It "does not prompt when no catalog distro is currently registered" {
        Mock Test-WinUtilWSLDistroInstalled { $false }
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }

        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName Show-WinUtilMessage -Times 0 -Exactly
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--uninstall" }
    }

    It "never touches an application entry that isn't a catalog WSL distro, even from the same hashtable" {
        # Regression guard: only installType "wslDistro" entries get unregistered here - an
        # unrelated catalog entry (Chrome) sitting in the same applicationsHashtable must never
        # be passed to wsl.exe.
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }

        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName wsl -Times 0 -Exactly -ParameterFilter { ($Arguments -join " ") -like "*Chrome*" }
    }

    It "does not unregister or prompt if no WSL distro is declared in the catalog" {
        $script:sync.configs.applicationsHashtable.Remove("WPFInstalldebian")
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }

        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package)

        Should -Invoke -CommandName Show-WinUtilMessage -Times 0 -Exactly
        Should -Invoke -CommandName wsl -Times 0 -Exactly -ParameterFilter { ($Arguments -join " ") -like "*unregister*" }
        Should -Invoke -CommandName wsl -Times 1 -Exactly -ParameterFilter { ($Arguments -join " ") -eq "--uninstall" }
    }

    It "logs a placeholder instead of crashing when wsl --uninstall produces no console output" {
        # Regression guard for the exact reported crash: "wsl --uninstall" completed with empty
        # console output, and passing that straight to Write-WinUtilLog's Mandatory -Message
        # threw, which was then caught and misreported as "Failed to uninstall WSL2".
        Mock Show-WinUtilMessage { [System.Windows.MessageBoxResult]::Yes }
        Mock wsl { $global:LASTEXITCODE = 0; "" } -ParameterFilter { ($Arguments -join " ") -eq "--uninstall" }
        # Stateful: true on the first check (still registered, so Uninstall-WinUtilWSLDistro's
        # unregister attempt proceeds), false afterward (confirms it actually got removed).
        $script:distroStillRegistered = $true
        Mock Test-WinUtilWSLDistroInstalled {
            $result = $script:distroStillRegistered
            $script:distroStillRegistered = $false
            $result
        }

        $wsl2Package = [pscustomobject]@{ content = "WSL2" }
        { Uninstall-WinUtilFeatureWSL -Packages @($wsl2Package) } | Should -Not -Throw

        Should -Invoke -CommandName Write-WinUtilLog -Times 0 -Exactly -ParameterFilter { $Level -eq "ERROR" }
        # Exact match, not -like "*no console output*" - Uninstall-WinUtilWSLDistro's own
        # "--unregister" call also produces empty output from the same default wsl mock (since
        # only "--uninstall" is overridden above), so a loose match would double-count both.
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Message -eq "(wsl --uninstall completed with no console output)" }

        Remove-Variable -Name distroStillRegistered -Scope Script -ErrorAction SilentlyContinue
    }
}
