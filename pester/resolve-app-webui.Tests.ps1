#===========================================================================
# Tests - Resolve-WinUtilAppWebUI (dynamic port substitution for the "Open" button)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilAppWebUI.ps1")
}

Describe "Resolve-WinUtilAppWebUI" {
    It "returns `$null when the app has no webui at all" {
        $appObject = [pscustomobject]@{ content = "Clicker" }

        Resolve-WinUtilAppWebUI -AppObject $appObject | Should -BeNullOrEmpty
    }

    It "returns the webui unchanged when the app doesn't declare webuiPortEnvVar" {
        # Regression guard: this must be a complete no-op for the rest of the catalog, which
        # doesn't declare webuiPortEnvVar at all.
        $appObject = [pscustomobject]@{ content = "OliveTin EZ-Start"; webui = "http://localhost:1337" }

        Resolve-WinUtilAppWebUI -AppObject $appObject | Should -Be "http://localhost:1337"
    }

    It "returns the webui unchanged when the declared env var isn't set" {
        $appObject = [pscustomobject]@{ content = "Streaming Library Manager"; webui = "http://localhost:5000"; webuiPortEnvVar = "SLM_PORT_THAT_DOES_NOT_EXIST_$([guid]::NewGuid().ToString('N'))" }

        Resolve-WinUtilAppWebUI -AppObject $appObject | Should -Be "http://localhost:5000"
    }

    It "substitutes the env var's port into the URL when it's set" {
        # Regression guard for the actual author-reported bug: the "Open Web Interface" button
        # was hardcoded to the catalog's declared default port even after SLM_PORT was set to
        # something else during install - the popup always opened the wrong port.
        $envName = "SLM_PORT_TEST_$([guid]::NewGuid().ToString('N'))"
        [Environment]::SetEnvironmentVariable($envName, "7654", "User")
        try {
            $appObject = [pscustomobject]@{ content = "Streaming Library Manager"; webui = "http://localhost:5000"; webuiPortEnvVar = $envName }

            Resolve-WinUtilAppWebUI -AppObject $appObject | Should -Be "http://localhost:7654"
        } finally {
            [Environment]::SetEnvironmentVariable($envName, $null, "User")
        }
    }

    It "substitutes the port even when the URL has a path after it" {
        $envName = "SLM_PORT_TEST_$([guid]::NewGuid().ToString('N'))"
        [Environment]::SetEnvironmentVariable($envName, "7654", "User")
        try {
            $appObject = [pscustomobject]@{ content = "Example"; webui = "http://localhost:5000/status"; webuiPortEnvVar = $envName }

            Resolve-WinUtilAppWebUI -AppObject $appObject | Should -Be "http://localhost:7654/status"
        } finally {
            [Environment]::SetEnvironmentVariable($envName, $null, "User")
        }
    }

    It "returns the webui unchanged when the env var's value isn't a valid port" {
        $envName = "SLM_PORT_TEST_$([guid]::NewGuid().ToString('N'))"
        [Environment]::SetEnvironmentVariable($envName, "not-a-port", "User")
        try {
            $appObject = [pscustomobject]@{ content = "Example"; webui = "http://localhost:5000"; webuiPortEnvVar = $envName }

            Resolve-WinUtilAppWebUI -AppObject $appObject | Should -Be "http://localhost:5000"
        } finally {
            [Environment]::SetEnvironmentVariable($envName, $null, "User")
        }
    }
}
