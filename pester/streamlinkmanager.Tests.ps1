#===========================================================================
# Tests - Streaming Library Manager install/uninstall progress reporting
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilStreamLinkManager.ps1")
    . (Join-Path $script:repoRoot "functions\private\Uninstall-WinUtilStreamLinkManager.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }
    function schtasks { param([Parameter(ValueFromRemainingArguments = $true)]$Arguments) }
    function Start-WinUtilProcessAsStandardUserNoWait { param($FilePath, $ArgumentList) }
    function Set-WinUtilProcessForeground { param($Process) }

    function script:New-WinUtilSlmPackage {
        [pscustomobject]@{ content = "Streaming Library Manager"; webui = "http://localhost:8815" }
    }
}

Describe "Install-WinUtilStreamLinkManager" {
    BeforeEach {
        Mock Get-Process { }
        Mock Stop-Process { }
        Mock New-Item { }
        Mock Invoke-WebRequest { }
        Mock Expand-Archive { }
        Mock Copy-Item { }
        Mock Test-Path { $true }
        Mock schtasks { }
        Mock Start-Process { }
        Mock Remove-Item { }
        Mock Start-WinUtilProcessAsStandardUserNoWait { $true }
        Mock Set-WinUtilProcessForeground { }
    }

    It "reports each milestone via ProgressCallback, in order, when supplied" {
        # Regression guard for the real reported bug: this install (a single Dropbox download +
        # extract with no per-step feedback beyond log lines) looked frozen at 0% for however
        # long the whole thing took - ProgressCallback is what fixes that.
        $messages = [System.Collections.Generic.List[string]]::new()

        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @(
            "Installing Streaming Library Manager..."
            "Downloading Streaming Library Manager..."
            "Extracting Streaming Library Manager..."
            "Starting Streaming Library Manager..."
        )
    }

    It "does not require a ProgressCallback" {
        { Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) } | Should -Not -Throw
    }

    It "does not let a failing ProgressCallback abort the install" {
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) -ProgressCallback { throw "boom" }

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly
    }

    It "launches the app de-elevated, not inheriting WinUtil's own elevated context" {
        # Regression guard: a background tray app with no functional need for admin rights
        # (organizing local media library data, serving a local web UI) used to launch elevated
        # simply because it ran inside WinUtil's own elevated process, same as slm.bat's own
        # script does - unnecessary elevation of a persistent user app.
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Start-WinUtilProcessAsStandardUserNoWait -Times 1 -Exactly -ParameterFilter {
            $FilePath -like "*slm.exe"
        }
        Should -Invoke -CommandName Start-Process -Times 0 -Exactly
    }

    It "falls back to an elevated launch when de-elevation fails" {
        Mock Start-WinUtilProcessAsStandardUserNoWait { $false }

        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like "*slm.exe"
        }
    }

    It "registers the at-logon scheduled task with a de-elevated (Limited) RunLevel, not elevated (highest)" {
        # Same reasoning as the initial launch above - the task fires at every subsequent login,
        # so leaving it elevated would re-introduce the same unnecessary-admin problem on every
        # boot even after fixing the one-time install-time launch.
        Install-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage)

        Should -Invoke -CommandName schtasks -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains "/rl" -and $Arguments -contains "limited" -and $Arguments -notcontains "highest"
        }
    }
}

Describe "Uninstall-WinUtilStreamLinkManager" {
    BeforeEach {
        Mock Get-Process { }
        Mock Stop-Process { }
        Mock schtasks { }
        Mock Test-Path { $true }
        Mock Remove-Item { }
    }

    It "reports the uninstall milestone via ProgressCallback when supplied" {
        $messages = [System.Collections.Generic.List[string]]::new()

        Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) -ProgressCallback {
            param($message) $messages.Add($message)
        }

        $messages | Should -Be @("Uninstalling Streaming Library Manager...")
    }

    It "does not require a ProgressCallback" {
        { Uninstall-WinUtilStreamLinkManager -Packages @(New-WinUtilSlmPackage) } | Should -Not -Throw
    }
}
