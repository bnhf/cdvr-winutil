function Resolve-WinUtilPackagePrompts {
    <#
    .SYNOPSIS
        For each package that declares "prompts" (e.g. a password to bake into a command),
        shows an input dialog and attaches the entered values as .PromptValues. If the user
        cancels, the package is dropped from the run.

        Must be called from the UI thread - before the selection is handed off to the
        background install runspace, which may not be an STA thread and cannot reliably
        show its own dialogs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PackagesToInstall
    )

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $PackagesToInstall) {
        if (-not $package.prompts -or @($package.prompts).Count -eq 0) {
            $result.Add($package)
            continue
        }

        $values = Show-WinUtilPromptDialog -Title $package.content -Message "$($package.content) needs a few values before installing:" -Prompts $package.prompts

        if ($null -eq $values) {
            Write-WinUtilLog -Level "WARN" -Component "Install" -Message "Skipping $($package.content) - prompt cancelled."
            continue
        }

        $packageWithValues = $package | Add-Member -NotePropertyName PromptValues -NotePropertyValue $values -PassThru -Force
        $result.Add($packageWithValues)
    }

    return $result.ToArray()
}
