#===========================================================================
# Tests - Update-WinUtilSessionPath and its npm-related callers
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Update-WinUtilSessionPath.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramNpm.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilNpmPackageInstalled.ps1")

    # Must declare its parameters (not just take $args implicitly) - Pester's Mock generates
    # its proxy from THIS stub's own signature, since Write-WinUtilLog isn't a real cmdlet, and
    # a parameterless stub gives Should -Invoke -ParameterFilter nothing to bind $Level/$Message
    # against when re-evaluating recorded calls (confirmed live: the filter ran "without any
    # context" and every call looked like a non-match, even ones that clearly weren't).
    function Write-WinUtilLog { param($Message, $Level, $Component) }
}

Describe "Update-WinUtilSessionPath" {
    It "sets env:Path to the join of the real Machine and User registry Path values" {
        $expectedMachine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $expectedUser = [System.Environment]::GetEnvironmentVariable("Path", "User")

        Update-WinUtilSessionPath

        $env:Path | Should -Be (@($expectedMachine, $expectedUser) -join ";")
    }
}

Describe "Install-WinUtilProgramNpm PATH refresh" {
    BeforeEach {
        Mock Write-WinUtilLog { }
    }

    It "refreshes PATH before checking whether npm is available, so a just-installed Node.js is seen" {
        # Regression guard for the actual reported bug: installing Node.js via winget, then
        # immediately installing an npm-type package (e.g. Prismcast) in the same run, failed
        # with "npm is not on PATH" even though Node.js had just installed successfully -
        # $env:Path is only populated at process start and never picks up what an installer adds
        # to the registry afterward, so Get-Command npm kept resolving against the STALE PATH
        # captured before Node.js existed. Simulates that exact shape: Get-Command only "sees"
        # npm once Update-WinUtilSessionPath has actually run first.
        $script:pathRefreshed = $false
        Mock Update-WinUtilSessionPath { $script:pathRefreshed = $true }
        Mock Get-Command {
            if ($script:pathRefreshed) { [pscustomobject]@{ Name = "npm" } } else { $null }
        } -ParameterFilter { $Name -eq "npm" }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast" }
        Install-WinUtilProgramNpm -Action Install -Packages @($pkg)

        Should -Invoke -CommandName Update-WinUtilSessionPath -Times 1 -Exactly
        # Via cmd.exe /c, not a direct "npm" FilePath - see Install-WinUtilProgramNpm's own
        # docstring for why (npm is a .cmd batch shim on Windows, and Start-Process -NoNewWindow
        # can't execute one directly: "%1 is not a valid Win32 application").
        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq "cmd.exe" -and (@($ArgumentList) -join "|") -eq "/c|npm|install|-g|prismcast"
        }
    }
}

Describe "Install-WinUtilProgramNpm --allow-scripts" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Update-WinUtilSessionPath { }
        Mock Get-Command { [pscustomobject]@{ Name = "npm" } } -ParameterFilter { $Name -eq "npm" }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "passes --allow-scripts through for a package that declares npmAllowScripts" {
        # Regression guard for the actual reported bug: npm silently skips a dependency's own
        # install/postinstall script unless explicitly allowlisted - confirmed live for
        # Prismcast, whose ffmpeg-for-homebridge dependency needs its install.js to actually
        # fetch the bundled ffmpeg binary Prismcast depends on, only logged as an npm warning
        # rather than a failure, so nothing about the install itself signaled anything was wrong.
        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast"; npmAllowScripts = "ffmpeg-for-homebridge" }

        Install-WinUtilProgramNpm -Action Install -Packages @($pkg)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            (@($ArgumentList) -join "|") -eq "/c|npm|install|-g|prismcast|--allow-scripts=ffmpeg-for-homebridge"
        }
    }

    It "does not pass --allow-scripts for a package that doesn't declare it" {
        # Deliberately per-package, not a blanket allow for every npm-type install - most npm
        # packages have no declared need to bypass npm's own default-deny script protection.
        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast" }

        Install-WinUtilProgramNpm -Action Install -Packages @($pkg)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            (@($ArgumentList) -join "|") -eq "/c|npm|install|-g|prismcast"
        }
    }

    It "does not pass --allow-scripts on uninstall, even when the package declares it" {
        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast"; npmAllowScripts = "ffmpeg-for-homebridge" }

        Install-WinUtilProgramNpm -Action Uninstall -Packages @($pkg)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            (@($ArgumentList) -join "|") -eq "/c|npm|uninstall|-g|prismcast"
        }
    }
}

Describe "Install-WinUtilProgramNpm preUninstallCommand" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Update-WinUtilSessionPath { }
        Mock Get-Command { [pscustomobject]@{ Name = "npm" } } -ParameterFilter { $Name -eq "npm" }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "runs preUninstallCommand before the npm uninstall itself, for a package that declares one" {
        # Regression guard for the actual reported bug: uninstalling Prismcast failed with npm
        # error EBUSY ("resource busy or locked") trying to rename/delete its package folder,
        # because the background Windows service it registers at install time
        # ("prismcast service install") was still running and holding those files open. This
        # mechanism (mirroring postInstallCommand's own "run something around the npm call"
        # shape) is what makes the catalog's own fix possible - see Install-WinUtilProgramNpm's
        # own docstring for what that catalog value actually needs to run and why (confirmed via
        # Prismcast's own source: "service uninstall" alone never stops the running process).
        Remove-Variable -Name preUninstallRanBeforeNpm -Scope Script -ErrorAction SilentlyContinue
        Mock Start-Process {
            $script:preUninstallRanBeforeNpm = $script:preUninstallRan -eq $true
            [pscustomobject]@{ ExitCode = 0 }
        }
        $pkg = [pscustomobject]@{
            content = "Prismcast"; npmPackage = "prismcast"
            preUninstallCommand = 'Set-Variable -Name preUninstallRan -Value $true -Scope Script'
        }

        Install-WinUtilProgramNpm -Action Uninstall -Packages @($pkg)

        $script:preUninstallRan | Should -BeTrue
        $script:preUninstallRanBeforeNpm | Should -BeTrue
        Remove-Variable -Name preUninstallRan -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name preUninstallRanBeforeNpm -Scope Script -ErrorAction SilentlyContinue
    }

    It "does not run preUninstallCommand on install, even when the package declares one" {
        Remove-Variable -Name preUninstallRan -Scope Script -ErrorAction SilentlyContinue
        $pkg = [pscustomobject]@{
            content = "Prismcast"; npmPackage = "prismcast"
            preUninstallCommand = 'Set-Variable -Name preUninstallRan -Value $true -Scope Script'
        }

        Install-WinUtilProgramNpm -Action Install -Packages @($pkg)

        $script:preUninstallRan | Should -BeNullOrEmpty
    }

    It "does not require a preUninstallCommand" {
        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast" }

        { Install-WinUtilProgramNpm -Action Uninstall -Packages @($pkg) } | Should -Not -Throw
    }

    It "still attempts the npm uninstall even when preUninstallCommand itself fails" {
        $pkg = [pscustomobject]@{
            content = "Prismcast"; npmPackage = "prismcast"
            preUninstallCommand = 'throw "boom"'
        }

        Install-WinUtilProgramNpm -Action Uninstall -Packages @($pkg)

        Should -Invoke -CommandName Start-Process -Times 1 -Exactly -ParameterFilter {
            (@($ArgumentList) -join "|") -eq "/c|npm|uninstall|-g|prismcast"
        }
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "ERROR" -and $Message -like "Pre-uninstall step failed for Prismcast*"
        }
    }
}

Describe "Install-WinUtilProgramNpm process cleanup before uninstall" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        Mock Update-WinUtilSessionPath { }
        Mock Get-Command { [pscustomobject]@{ Name = "npm" } } -ParameterFilter { $Name -eq "npm" }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Start-Sleep { }
        Mock Get-CimInstance { }
        Mock Stop-Process { }
    }

    It "stops a node.exe process whose command line references this package's own files" {
        # Regression guard for the actual reported bug, across three separate live rounds:
        # Prismcast's own declared shutdown command ("prismcast service stop") reported success
        # but npm's uninstall still failed with EBUSY afterward regardless - reading Prismcast's
        # own source explained the FIRST failure (a missing "service stop" call), but even
        # fixing that didn't resolve it, meaning the package's own shutdown path can't be
        # trusted to have actually released its files. This finds and stops the real culprit
        # directly, independent of whatever the package's own preUninstallCommand did or didn't
        # accomplish.
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ ProcessId = 4242; CommandLine = 'node.exe "C:\Users\slayer\AppData\Roaming\npm\node_modules\prismcast\dist\index.js"' }
                [pscustomobject]@{ ProcessId = 9999; CommandLine = 'node.exe "C:\some\other\node_modules\unrelated-tool\index.js"' }
            )
        } -ParameterFilter { $ClassName -eq "Win32_Process" -and $Filter -eq "Name='node.exe'" }
        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast" }

        Install-WinUtilProgramNpm -Action Uninstall -Packages @($pkg)

        Should -Invoke -CommandName Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 }
        Should -Invoke -CommandName Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 9999 }
    }

    It "runs the cleanup even when the package has no preUninstallCommand declared" {
        Mock Get-CimInstance {
            [pscustomobject]@{ ProcessId = 4242; CommandLine = 'node.exe ".../node_modules/prismcast/dist/index.js"' }
        } -ParameterFilter { $ClassName -eq "Win32_Process" -and $Filter -eq "Name='node.exe'" }
        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast" }

        Install-WinUtilProgramNpm -Action Uninstall -Packages @($pkg)

        Should -Invoke -CommandName Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 }
    }

    It "does not run the cleanup (or stop anything) on install" {
        $pkg = [pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast" }

        Install-WinUtilProgramNpm -Action Install -Packages @($pkg)

        Should -Invoke -CommandName Get-CimInstance -Times 0 -Exactly
        Should -Invoke -CommandName Stop-Process -Times 0 -Exactly
    }

    It "does not throw or stop anything when no matching process is found" {
        { Install-WinUtilProgramNpm -Action Uninstall -Packages @([pscustomobject]@{ content = "Prismcast"; npmPackage = "prismcast" }) } | Should -Not -Throw

        Should -Invoke -CommandName Stop-Process -Times 0 -Exactly
    }
}

Describe "Test-WinUtilNpmPackageInstalled PATH refresh" {
    It "refreshes PATH unconditionally before checking whether npm is available" {
        # Same wiring as Install-WinUtilProgramNpm above - "Show Installed Apps" can run in the
        # same session right after Node.js installed, before this process would otherwise see
        # it. Get-Command is kept returning $null here (npm still not found) so the function
        # never reaches its real "& npm list -g ..." call, which would otherwise try to launch
        # an actual npm process in this test - the point of this test is only to confirm the
        # refresh happens, not to exercise a real npm invocation.
        Mock Update-WinUtilSessionPath { }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq "npm" }

        $result = Test-WinUtilNpmPackageInstalled -NpmPackage "prismcast"

        $result | Should -Be $false
        Should -Invoke -CommandName Update-WinUtilSessionPath -Times 1 -Exactly
    }
}
