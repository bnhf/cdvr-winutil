#===========================================================================
# Tests - Resolve-WinUtilPackagePrompts
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Resolve-WinUtilPackagePrompts.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }
    function Show-WinUtilPromptDialog { param($Title, $Message, $Prompts) }
    function Get-WinUtilNodeJsVersionChoices { }
}

Describe "Resolve-WinUtilPackagePrompts" {
    BeforeEach {
        Mock Write-WinUtilLog { }
    }

    It "passes a package through unchanged when it declares no prompts" {
        Mock Show-WinUtilPromptDialog { }
        $package = [pscustomobject]@{ content = "Git" }

        $result = Resolve-WinUtilPackagePrompts -PackagesToInstall @($package)

        $result.Count | Should -Be 1
        $result[0].content | Should -Be "Git"
        Should -Invoke -CommandName Show-WinUtilPromptDialog -Times 0 -Exactly
    }

    It "attaches the entered values as PromptValues when the dialog isn't cancelled" {
        Mock Show-WinUtilPromptDialog { @{ SLM_PORT = "7654" } }
        $package = [pscustomobject]@{
            content = "Streaming Library Manager"
            prompts = @([pscustomobject]@{ name = "SLM_PORT"; label = "Port" })
        }

        $result = Resolve-WinUtilPackagePrompts -PackagesToInstall @($package)

        $result.Count | Should -Be 1
        $result[0].PromptValues["SLM_PORT"] | Should -Be "7654"
    }

    It "drops the package and warns when the dialog is cancelled" {
        Mock Show-WinUtilPromptDialog { $null }
        $package = [pscustomobject]@{
            content = "Streaming Library Manager"
            prompts = @([pscustomobject]@{ name = "SLM_PORT"; label = "Port" })
        }

        $result = Resolve-WinUtilPackagePrompts -PackagesToInstall @($package)

        $result.Count | Should -Be 0
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" }
    }

    It "resolves a prompt's default from defaultEnvVar's current value when it's set" {
        # Regression guard for an author-reported gap: Streaming Library Manager's SLM_PORT
        # prompt should default to the port it's already configured with on a reinstall/upgrade,
        # not silently fall back to the catalog's plain default every time.
        $envName = "SLM_PORT_TEST_$([guid]::NewGuid().ToString('N'))"
        [Environment]::SetEnvironmentVariable($envName, "7654", "User")
        try {
            $capturedPrompts = $null
            Mock Show-WinUtilPromptDialog {
                $script:capturedPrompts = $Prompts
                @{ SLM_PORT = "7654" }
            }
            $package = [pscustomobject]@{
                content = "Streaming Library Manager"
                prompts = @([pscustomobject]@{ name = "SLM_PORT"; label = "Port"; default = "5000"; defaultEnvVar = $envName })
            }

            Resolve-WinUtilPackagePrompts -PackagesToInstall @($package) | Out-Null

            ($script:capturedPrompts | Where-Object { $_.name -eq "SLM_PORT" }).default | Should -Be "7654"
        } finally {
            [Environment]::SetEnvironmentVariable($envName, $null, "User")
        }
    }

    It "falls back to the prompt's own plain default when defaultEnvVar isn't set" {
        $envName = "SLM_PORT_TEST_$([guid]::NewGuid().ToString('N'))"
        $capturedPrompts = $null
        Mock Show-WinUtilPromptDialog {
            $script:capturedPrompts = $Prompts
            @{ SLM_PORT = "5000" }
        }
        $package = [pscustomobject]@{
            content = "Streaming Library Manager"
            prompts = @([pscustomobject]@{ name = "SLM_PORT"; label = "Port"; default = "5000"; defaultEnvVar = $envName })
        }

        Resolve-WinUtilPackagePrompts -PackagesToInstall @($package) | Out-Null

        ($script:capturedPrompts | Where-Object { $_.name -eq "SLM_PORT" }).default | Should -Be "5000"
    }

    It "leaves prompts with no defaultEnvVar at all completely unaffected" {
        # Regression guard: this must be a no-op for every other prompt in the catalog (e.g.
        # Olivetin's PORTAINER_PASSWORD), none of which declare defaultEnvVar.
        $capturedPrompts = $null
        Mock Show-WinUtilPromptDialog {
            $script:capturedPrompts = $Prompts
            @{ PORTAINER_PASSWORD = "hunter2hunter2" }
        }
        $package = [pscustomobject]@{
            content = "Olivetin EZ-Start"
            prompts = @([pscustomobject]@{ name = "PORTAINER_PASSWORD"; label = "Password"; secret = $true; minLength = 12 })
        }

        Resolve-WinUtilPackagePrompts -PackagesToInstall @($package) | Out-Null

        $prompt = $script:capturedPrompts | Where-Object { $_.name -eq "PORTAINER_PASSWORD" }
        $prompt.secret | Should -Be $true
        $prompt.minLength | Should -Be 12
        $prompt.default | Should -BeNullOrEmpty
    }

    It "resolves a prompt's choices and default from its choicesProvider" {
        Mock Get-WinUtilNodeJsVersionChoices {
            [pscustomobject]@{
                Choices = @([pscustomobject]@{ Value = "24.13.0"; Label = "24.13.0 (Current)" }, [pscustomobject]@{ Value = "22.11.0"; Label = "22.11.0 (LTS: Jod)" })
                Default = "24.13.0"
            }
        }
        $capturedPrompts = $null
        Mock Show-WinUtilPromptDialog {
            $script:capturedPrompts = $Prompts
            @{ NODEJS_VERSION = "24.13.0" }
        }
        $package = [pscustomobject]@{
            content = "Node.js"
            winget  = "OpenJS.NodeJS"
            wingetVersionPrompt = "NODEJS_VERSION"
            prompts = @([pscustomobject]@{ name = "NODEJS_VERSION"; label = "Version"; default = "24.13.0"; choicesProvider = "NodeJsVersions" })
        }

        Resolve-WinUtilPackagePrompts -PackagesToInstall @($package) | Out-Null

        $prompt = $script:capturedPrompts | Where-Object { $_.name -eq "NODEJS_VERSION" }
        $prompt.default | Should -Be "24.13.0"
        @($prompt.choices).Count | Should -Be 2
        ($prompt.choices | Where-Object { $_.Value -eq "22.11.0" }).Label | Should -Be "22.11.0 (LTS: Jod)"
    }

    It "appends the chosen version to a package's winget id when wingetVersionPrompt is declared" {
        Mock Show-WinUtilPromptDialog { @{ NODEJS_VERSION = "22.11.0" } }
        $package = [pscustomobject]@{
            content = "Node.js"
            winget  = "OpenJS.NodeJS"
            wingetVersionPrompt = "NODEJS_VERSION"
            prompts = @([pscustomobject]@{ name = "NODEJS_VERSION"; label = "Version"; default = "24.13.0" })
        }

        $result = Resolve-WinUtilPackagePrompts -PackagesToInstall @($package)

        $result[0].winget | Should -Be "OpenJS.NodeJS@22.11.0"
    }

    It "leaves a package's winget id unchanged when wingetVersionPrompt isn't declared" {
        # Regression guard: every other prompt-declaring package in the catalog (Olivetin,
        # Streaming Library Manager) must be completely unaffected by this new field.
        Mock Show-WinUtilPromptDialog { @{ SLM_PORT = "7654" } }
        $package = [pscustomobject]@{
            content = "Streaming Library Manager"
            winget  = "na"
            prompts = @([pscustomobject]@{ name = "SLM_PORT"; label = "Port" })
        }

        $result = Resolve-WinUtilPackagePrompts -PackagesToInstall @($package)

        $result[0].winget | Should -Be "na"
    }
}
