function Resolve-WinUtilPackagePrompts {
    <#
    .SYNOPSIS
        For each package that declares "prompts" (e.g. a password to bake into a command),
        shows an input dialog and attaches the entered values as .PromptValues. If the user
        cancels, the package is dropped from the run.

        Must be called from the UI thread - before the selection is handed off to the
        background install runspace, which may not be an STA thread and cannot reliably
        show its own dialogs.

    .DESCRIPTION
        A prompt declaring "defaultEnvVar" gets its dialog default resolved here, from that
        environment variable's CURRENT value, immediately before the dialog is shown - not
        baked into the catalog's own static JSON, which can't express "whatever this is set to
        right now." Author-confirmed use case: Streaming Library Manager's SLM_PORT prompt
        should default to the port it's already configured with on a reinstall/upgrade, not
        silently fall back to the catalog's plain 5000 every time. Falls back to the prompt's
        own plain "default" (or none at all) when the env var isn't set - most prompts declare
        neither and are completely unaffected. Built as a new prompt object per package rather
        than mutating $package.prompts in place, since that array is the shared, cached catalog
        object every other install of the same app would also read.

        A prompt declaring "choicesProvider" gets its "choices" resolved here too, the same way
        "defaultEnvVar" resolves "default" - a live, bounded list (e.g. Node.js's version
        picker, sourced from nodejs.org) that can't be expressed as static catalog JSON. The
        provider name is a small switch below, not an arbitrary function name from JSON, so the
        catalog can't invoke code it doesn't already know about.

        A package declaring "wingetVersionPrompt" (naming one of its own prompts) gets that
        prompt's chosen value appended to its own .winget id as "<id>@<version>" once the dialog
        resolves - Install-WinUtilProgramWinget reads that suffix and passes it on as winget's
        own --version. Only affects this run's in-memory package copy, never the shared catalog
        object, and only when a winget id is actually present.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$PackagesToInstall
    )

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $PackagesToInstall) {
        if (-not $package.prompts -or @($package.prompts).Count -eq 0) {
            $result.Add($package)
            continue
        }

        $resolvedPrompts = @($package.prompts | ForEach-Object {
            $prompt = $_
            $defaultValue = $prompt.default
            if (-not [string]::IsNullOrWhiteSpace($prompt.defaultEnvVar)) {
                $envValue = [Environment]::GetEnvironmentVariable($prompt.defaultEnvVar, "User")
                if (-not [string]::IsNullOrWhiteSpace($envValue)) {
                    $defaultValue = $envValue
                }
            }
            $choices = $null
            if (-not [string]::IsNullOrWhiteSpace($prompt.choicesProvider)) {
                $provided = switch ($prompt.choicesProvider) {
                    "NodeJsVersions" { Get-WinUtilNodeJsVersionChoices }
                    default {
                        Write-WinUtilLog -Level "WARN" -Component "Install" -Message "$($package.content) prompt '$($prompt.name)' declares unknown choicesProvider '$($prompt.choicesProvider)'."
                        $null
                    }
                }
                if ($provided) {
                    $choices = $provided.Choices
                    if (-not [string]::IsNullOrWhiteSpace($provided.Default)) {
                        $defaultValue = $provided.Default
                    }
                }
            }

            [pscustomobject]@{
                name      = $prompt.name
                label     = $prompt.label
                secret    = $prompt.secret
                minLength = $prompt.minLength
                default   = $defaultValue
                choices   = $choices
            }
        })

        $values = Show-WinUtilPromptDialog -Title $package.content -Message "$($package.content) needs a few values before installing:" -Prompts $resolvedPrompts

        if ($null -eq $values) {
            Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping $($package.content) - prompt cancelled."
            continue
        }

        $packageWithValues = $package | Add-Member -NotePropertyName PromptValues -NotePropertyValue $values -PassThru -Force

        if (-not [string]::IsNullOrWhiteSpace($package.wingetVersionPrompt) -and
            -not [string]::IsNullOrWhiteSpace($packageWithValues.winget) -and
            $packageWithValues.winget -ne "na") {
            $selectedVersion = $values[$package.wingetVersionPrompt]
            if (-not [string]::IsNullOrWhiteSpace($selectedVersion)) {
                $packageWithValues.winget = "$($packageWithValues.winget)@$selectedVersion"
            }
        }

        $result.Add($packageWithValues)
    }

    # The leading comma matters: PowerShell unwraps a returned empty array to $null across the
    # function-return boundary (e.g. if every remaining package's prompt gets cancelled) - see
    # Resolve-WinUtilPrerequisites.ps1 for the exception that caused downstream.
    return ,$result.ToArray()
}
