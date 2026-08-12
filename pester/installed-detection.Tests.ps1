#===========================================================================
# Tests - Test-WinUtilWebUIReachable / Test-WinUtilWSLCommandInstalled
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

Describe "Test-WinUtilWebUIReachable" {
    BeforeAll {
        . (Join-Path $script:repoRoot "functions\private\Test-WinUtilWebUIReachable.ps1")
    }

    It "returns false for a URL nothing is listening on" {
        # A reserved TEST-NET address (RFC 5737) with an arbitrary high port - guaranteed
        # unreachable without depending on any real network state.
        Test-WinUtilWebUIReachable -Url "http://192.0.2.1:1" | Should -BeFalse
    }

    It "returns false rather than throwing on a malformed URL" {
        { Test-WinUtilWebUIReachable -Url "not a url" } | Should -Not -Throw
        Test-WinUtilWebUIReachable -Url "not a url" | Should -BeFalse
    }

    It "returns true for a port something is actually listening on" {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            Test-WinUtilWebUIReachable -Url "http://127.0.0.1:$port" | Should -BeTrue
        } finally {
            $listener.Stop()
        }
    }
}

Describe "Test-WinUtilWSLCommandInstalled" {
    BeforeAll {
        . (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilWithTimeout.ps1")
        . (Join-Path $script:repoRoot "functions\private\Test-WinUtilWSLCommandInstalled.ps1")

        function wsl {
            param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
        }
    }

    BeforeEach {
        Mock Invoke-WinUtilWithTimeout { & $ScriptBlock @ArgumentList }
    }

    It "returns true when the install check command exits 0" {
        Mock wsl { $global:LASTEXITCODE = 0 }

        Test-WinUtilWSLCommandInstalled -Distro "Debian" -InstallCheckCommand "docker inspect olivetin-ezstart" | Should -BeTrue
    }

    It "returns false when the install check command exits non-zero" {
        Mock wsl { $global:LASTEXITCODE = 1 }

        Test-WinUtilWSLCommandInstalled -Distro "Debian" -InstallCheckCommand "docker inspect olivetin-ezstart" | Should -BeFalse
    }

    It "returns false without calling wsl when Distro is missing" {
        Test-WinUtilWSLCommandInstalled -Distro "" -InstallCheckCommand "docker inspect olivetin-ezstart" | Should -BeFalse
        Should -Invoke -CommandName Invoke-WinUtilWithTimeout -Times 0 -Exactly
    }

    It "returns false without calling wsl when InstallCheckCommand is missing" {
        Test-WinUtilWSLCommandInstalled -Distro "Debian" -InstallCheckCommand "" | Should -BeFalse
        Should -Invoke -CommandName Invoke-WinUtilWithTimeout -Times 0 -Exactly
    }

    It "returns false rather than throwing when the timeout is exceeded" {
        Mock Invoke-WinUtilWithTimeout { $false }

        Test-WinUtilWSLCommandInstalled -Distro "Debian" -InstallCheckCommand "docker inspect olivetin-ezstart" | Should -BeFalse
    }
}
