#===========================================================================
# Tests - Update-WinUtilSessionPath and its npm-related callers
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Update-WinUtilSessionPath.ps1")
    . (Join-Path $script:repoRoot "functions\private\Install-WinUtilProgramNpm.ps1")
    . (Join-Path $script:repoRoot "functions\private\Test-WinUtilNpmPackageInstalled.ps1")

    function Write-WinUtilLog { }
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
