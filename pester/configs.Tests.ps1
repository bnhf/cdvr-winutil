#===========================================================================
# Tests - Config Files
#===========================================================================

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$configRoot = Join-Path $PSScriptRoot "..\config"
$functionRoot = Join-Path $repoRoot "functions"
$xamlPath = Join-Path $repoRoot "xaml\inputXML.xaml"
$mainScriptPath = Join-Path $repoRoot "scripts\main.ps1"
$buttonScriptPath = Join-Path $repoRoot "functions\public\Invoke-WPFButton.ps1"
$configCases = @(
    Get-ChildItem -Path $configRoot -Filter *.json | ForEach-Object {
        @{
            Name = $_.Name
            Path = $_.FullName
        }
    }
)

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:configRoot = Join-Path $script:repoRoot "config"
    $script:functionRoot = Join-Path $script:repoRoot "functions"
    $script:xamlPath = Join-Path $script:repoRoot "xaml\inputXML.xaml"
    $script:mainScriptPath = Join-Path $script:repoRoot "scripts\main.ps1"
    $script:buttonScriptPath = Join-Path $script:repoRoot "functions\public\Invoke-WPFButton.ps1"

function script:Get-WinUtilConfigObject {
    param([string]$Name)

    Get-Content -Path (Join-Path $script:configRoot "$Name.json") -Raw | ConvertFrom-Json
}

function script:Test-WinUtilHasProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return @($Object.PSObject.Properties.Name) -contains $Name
}

function script:Test-WinUtilHasNonEmptyProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-WinUtilHasProperty -Object $Object -Name $Name)) {
        return $false
    }

    $value = $Object.$Name
    if ($null -eq $value) {
        return $false
    }

    if ($value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($value)
    }

    if ($value -is [array]) {
        return @($value).Count -gt 0
    }

    return -not [string]::IsNullOrWhiteSpace([string]$value)
}

function script:Get-WinUtilMissingRequiredFields {
    param(
        [Parameter(Mandatory)]
        [string]$EntryName,

        [Parameter(Mandatory)]
        [psobject]$Entry,

        [Parameter(Mandatory)]
        [string[]]$RequiredFields
    )

    foreach ($field in $RequiredFields) {
        if (-not (Test-WinUtilHasNonEmptyProperty -Object $Entry -Name $field)) {
            "$EntryName missing $field"
        }
    }
}

function script:Get-WinUtilTopLevelFunctionNames {
    Get-ChildItem -Path $script:functionRoot -Filter *.ps1 -Recurse | ForEach-Object {
        $tokens = $null
        $syntaxErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$syntaxErrors)
        if ($syntaxErrors.Count -ne 0) {
            throw ($syntaxErrors | Out-String)
        }

        $ast.EndBlock.Statements |
            Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } |
            ForEach-Object { $_.Name }
    } | Sort-Object -Unique
}

function script:Get-WinUtilButtonSwitchNames {
    $buttonSource = Get-Content -Path $script:buttonScriptPath -Raw
    [regex]::Matches($buttonSource, '"(WPF[A-Za-z0-9_]+)"\s*\{') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
}
}

Describe "Config files" {
    foreach ($configCase in $configCases) {
        It "imports $($configCase.Name) with no JSON errors" -TestCases $configCase {
            param([string]$Name, [string]$Path)

            try {
                Get-Content -Path $Path -Raw | ConvertFrom-Json | Out-Null
            } catch {
                throw "Failed to import ${Name}: $_"
            }
        }
    }
}

Describe "Applications config" {
    $testCase = @{ Path = (Join-Path $configRoot "applications.json") }

    It "contains at least one application" -TestCases $testCase {
        param([string]$Path)

        $applications = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $applicationEntries = @($applications.PSObject.Properties)

        if ($applicationEntries.Count -eq 0) {
            throw "applications.json does not contain any application entries."
        }
    }

    It "contains required display fields and at least one install source" -TestCases $testCase {
        param([string]$Path)

        $applications = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $requiredFields = @("category", "content", "description", "link")
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $applications.PSObject.Properties) {
            $entryFields = @($entry.Value.PSObject.Properties.Name)

            foreach ($field in $requiredFields) {
                if ($entryFields -notcontains $field -or [string]::IsNullOrWhiteSpace([string]$entry.Value.$field)) {
                    $invalidEntries.Add("$($entry.Name) missing $field")
                }
            }

            $hasInstallSource = $false
            foreach ($sourceField in @("winget", "choco")) {
                if ($entryFields -contains $sourceField -and -not [string]::IsNullOrWhiteSpace([string]$entry.Value.$sourceField)) {
                    $hasInstallSource = $true
                }
            }

            $validInstallTypes = @("winget", "choco", "direct", "github", "npm", "wslFeature", "wslDistro", "wslCommand", "streamLinkManager")
            if ($entryFields -contains "installType" -and $validInstallTypes -contains [string]$entry.Value.installType) {
                $hasInstallSource = $true
            }

            if (-not $hasInstallSource) {
                $invalidEntries.Add("$($entry.Name) missing winget/choco install source or a valid installType")
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }

    It "has a 'Show Installed Apps' detection case for every installType used in the catalog" {
        # This closes a gap the "contains required display fields..." test above doesn't cover:
        # that test only confirms an installType is *recognized* for install/routing purposes,
        # not that "Show Installed Apps" (Invoke-WinUtilCurrentSystem.ps1) actually knows how to
        # detect it - which is exactly how two real bugs shipped undetected: github-type
        # detection that only worked for entries with a webui (Clicker doesn't have one), and
        # npm-type having no detection case at all (Prismcast) - both found only when a user
        # noticed a specific already-installed app not being checked, not by this test suite.
        # winget/choco aren't installTypes (those apps have no "installType" field at all) - they
        # go through the separate winget/choco checkbox branches earlier in the same function,
        # already covered by its own dedicated tests.
        $applications = Get-WinUtilConfigObject -Name "applications"
        $detectionScript = Get-Content -Path (Join-Path $script:repoRoot "functions\private\Invoke-WinUtilCurrentSystem.ps1") -Raw

        $installTypesInUse = @($applications.PSObject.Properties.Value.installType |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

        $missingCase = New-Object System.Collections.Generic.List[string]
        foreach ($installType in $installTypesInUse) {
            if ($detectionScript -notmatch [regex]::Escape('"' + $installType + '"')) {
                $missingCase.Add($installType)
            }
        }

        $missingCase | Should -BeNullOrEmpty -Because "Invoke-WinUtilCurrentSystem.ps1 has no 'Show Installed Apps' detection case for: $($missingCase -join ', ')"
    }
}

Describe "Tweaks config" {
    $testCase = @{ Path = (Join-Path $configRoot "tweaks.json") }

    It "contains undo metadata for registry and service actions" -TestCases $testCase {
        param([string]$Path)

        $tweaks = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $invalidTweaks = New-Object System.Collections.Generic.List[string]

        foreach ($tweak in $tweaks.PSObject.Properties) {
            foreach ($registryEntry in @($tweak.Value.registry)) {
                if ($null -eq $registryEntry) { continue }

                if ($registryEntry.PSObject.Properties.Name -notcontains "OriginalValue" -or
                    [string]::IsNullOrWhiteSpace([string]$registryEntry.OriginalValue)) {
                    $invalidTweaks.Add("$($tweak.Name),registry")
                }
            }

            foreach ($serviceEntry in @($tweak.Value.service)) {
                if ($null -eq $serviceEntry) { continue }

                if ($serviceEntry.PSObject.Properties.Name -notcontains "OriginalType" -or
                    [string]::IsNullOrWhiteSpace([string]$serviceEntry.OriginalType)) {
                    $invalidTweaks.Add("$($tweak.Name),service")
                }
            }
        }

        if ($invalidTweaks.Count -gt 0) {
            throw ($invalidTweaks -join "`n")
        }
    }
}

Describe "Preset config" {
    It "references existing config entries or supported actions" {
        $preset = Get-WinUtilConfigObject -Name "preset"
        $applications = Get-WinUtilConfigObject -Name "applications"
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"
        $feature = Get-WinUtilConfigObject -Name "feature"
        $appx = Get-WinUtilConfigObject -Name "appx"

        $validReferences = @(
            $tweaks.PSObject.Properties.Name
            $feature.PSObject.Properties.Name
            $appx.PSObject.Properties.Name
            $applications.PSObject.Properties.Name | ForEach-Object { "WPFInstall$_" }
            Get-WinUtilButtonSwitchNames
        ) | Sort-Object -Unique

        $invalidReferences = New-Object System.Collections.Generic.List[string]
        foreach ($presetEntry in $preset.PSObject.Properties) {
            foreach ($reference in @($presetEntry.Value)) {
                if ($validReferences -notcontains $reference) {
                    $invalidReferences.Add("$($presetEntry.Name) references missing item $reference")
                }
            }
        }

        if ($invalidReferences.Count -gt 0) {
            throw ($invalidReferences -join "`n")
        }
    }
}

Describe "Olivetin application config" {
    # Regression guard for the real production config, not just the function logic (already
    # covered generically in wsl-install.Tests.ps1) - EZ-Start's own "olivetin" and "portainer"
    # containers/images/volume are created by a bootstrapper (olivetin-ezstart) opaque to
    # WinUtil, so the only way to catch a future accidental edit breaking cleanup/stop behavior
    # is to check the actual command strings in applications.json.
    BeforeAll {
        $script:olivetin = (Get-WinUtilConfigObject -Name "applications").olivetin
    }

    It "only stops olivetin-ezstart after confirming the olivetin container is running" {
        $command = $script:olivetin.command
        $command | Should -Match "docker stop olivetin-ezstart"
        $command | Should -Match "status=running"

        $lines = $command -split "`n"
        $checkLine = (0..($lines.Count - 1) | Where-Object { $lines[$_] -match "docker ps -q" } | Select-Object -First 1)
        $stopLine = (0..($lines.Count - 1) | Where-Object { $lines[$_] -match "docker stop olivetin-ezstart" } | Select-Object -First 1)
        $stopLine | Should -BeGreaterThan $checkLine
    }

    It "removes the olivetin/portainer containers, their images, and the portainer_data volume on uninstall" {
        $uninstallCommand = $script:olivetin.uninstallCommand
        $uninstallCommand | Should -Match "docker rm -f olivetin-ezstart olivetin portainer"
        $uninstallCommand | Should -Match "docker volume rm portainer_data"
        $uninstallCommand | Should -Match "docker rmi"
    }

    It "declares upgradeInstructions pointing at Portainer, matching its installCheckCommand" {
        # Re-running the install command a second time fails (see the "only stops olivetin-
        # ezstart..." test above - the bootstrap container's name is already taken), and
        # Olivetin/Portainer are meant to be upgraded through Portainer's own UI, not this tool -
        # Install-WinUtilWSLCommand.ps1 only shows that dialog instead of re-running when both
        # fields are present, so a future edit dropping one silently disables the guard.
        $script:olivetin.installCheckCommand | Should -Not -BeNullOrEmpty
        $script:olivetin.upgradeInstructions | Should -Match "Portainer"
        $script:olivetin.upgradeInstructions | Should -Match "9000"
    }

    It "passes TZ as a plain IANA zone name, not the raw /etc/localtime symlink target" {
        # Regression guard: "readlink /etc/localtime" alone returns the full path the symlink
        # points at (e.g. "/usr/share/zoneinfo/America/Denver"), not the "America/Denver" form
        # Docker/OliveTin actually expect for TZ - confirmed live, this set the container's
        # timezone to that literal path instead of resolving it. /etc/timezone (Debian-specific)
        # already holds the plain zone name and is tried first; the symlink is only a fallback,
        # with its "/usr/share/zoneinfo/" (or any other) prefix stripped before use.
        $expectedTzPrefix = [regex]::Escape('$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime | sed')
        $expectedTzSuffix = [regex]::Escape("sed 's#.*zoneinfo/##')")
        $script:olivetin.command | Should -Match $expectedTzPrefix
        $script:olivetin.command | Should -Match $expectedTzSuffix
    }
}

Describe "Clicker application config" {
    # Regression guard: confirmed live, Clicker's Rust/WinUI3 executable fails to launch with
    # "VCRUNTIME140.dll was not found" without the VC++ Redistributable, which its own installer
    # doesn't bundle or check for - this silently pulls it in via postInstallCommand rather than
    # a separate visible catalog entry.
    It "silently installs the VC++ Redistributable after Clicker installs" {
        $rustdvr = (Get-WinUtilConfigObject -Name "applications").rustdvr

        $rustdvr.postInstallCommand | Should -Match ([regex]::Escape("Microsoft.VCRedist.2015+.x64"))
        $rustdvr.postInstallCommand | Should -Match "--silent"
    }
}

Describe "App navigation config" {
    It "is wired to an existing XAML target grid" {
        $mainScript = Get-Content -Path $script:mainScriptPath -Raw
        $tabInitializerScript = Get-Content -Path (Join-Path $script:repoRoot "functions/private/Initialize-WinUtilTabContent.ps1") -Raw
        $targetGridMatch = [regex]::Match(
            "$mainScript`n$tabInitializerScript",
            'Invoke-WPFUIElements\s+-configVariable\s+\$sync\.configs\.appnavigation\s+-targetGridName\s+"([^"]+)"'
        )

        if (-not $targetGridMatch.Success) {
            throw "Startup tab initialization does not wire appnavigation through Invoke-WPFUIElements."
        }

        $xamlText = Get-Content -Path $script:xamlPath -Raw
        $targetGridName = $targetGridMatch.Groups[1].Value
        if ($xamlText -notmatch "Name=`"$([regex]::Escape($targetGridName))`"") {
            throw "appnavigation target grid '$targetGridName' was not found in xaml/inputXML.xaml."
        }
    }

    It "contains renderable entries with valid button and radio groups" {
        $appnavigation = Get-WinUtilConfigObject -Name "appnavigation"
        $feature = Get-WinUtilConfigObject -Name "feature"
        $requiredFields = @("Content", "Category", "Type", "Order", "Description")
        $allowedTypes = @("Button", "RadioButton", "Note")
        $supportedButtons = @(
            Get-WinUtilButtonSwitchNames
            $feature.PSObject.Properties.Name
        ) | Sort-Object -Unique
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $appnavigation.PSObject.Properties) {
            foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName $entry.Name -Entry $entry.Value -RequiredFields $requiredFields)) {
                $invalidEntries.Add($missingField)
            }

            if ($allowedTypes -notcontains $entry.Value.Type) {
                $invalidEntries.Add("$($entry.Name) has unsupported Type '$($entry.Value.Type)'")
            }

            if ($entry.Value.Type -eq "Button" -and $supportedButtons -notcontains $entry.Name) {
                $invalidEntries.Add("$($entry.Name) is not handled by Invoke-WPFButton or feature config")
            }

            if ($entry.Value.Type -eq "RadioButton") {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name "GroupName")) {
                    $invalidEntries.Add("$($entry.Name) missing GroupName")
                }

                if (-not (Test-WinUtilHasProperty -Object $entry.Value -Name "Checked")) {
                    $invalidEntries.Add("$($entry.Name) missing Checked")
                }
            }
        }

        $radioButtons = @($appnavigation.PSObject.Properties | Where-Object { $_.Value.Type -eq "RadioButton" })
        foreach ($group in ($radioButtons | Group-Object -Property { $_.Value.GroupName })) {
            if ([string]::IsNullOrWhiteSpace($group.Name)) {
                $invalidEntries.Add("RadioButton group name is blank")
                continue
            }

            $checkedCount = @($group.Group | Where-Object { $_.Value.Checked -eq $true }).Count
            if ($checkedCount -ne 1) {
                $invalidEntries.Add("RadioButton group '$($group.Name)' has $checkedCount checked entries")
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }
}

Describe "UI-rendered config entries" {
    It "contains required AppX fields" {
        $appx = Get-WinUtilConfigObject -Name "appx"
        $requiredFields = @("Category", "Content", "Description", "Panel", "PackageId")
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $appx.PSObject.Properties) {
            foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName $entry.Name -Entry $entry.Value -RequiredFields $requiredFields)) {
                $invalidEntries.Add($missingField)
            }

            if ((Test-WinUtilHasProperty -Object $entry.Value -Name "StoreId") -and
                $entry.Value.StoreId -notmatch '^(?:[A-Z0-9]{12}|XP[A-Z0-9]{12})$') {
                $invalidEntries.Add("$($entry.Name) has invalid Microsoft Store ID '$($entry.Value.StoreId)'")
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }

    It "contains required DNS fields with parseable IP addresses" {
        $dns = Get-WinUtilConfigObject -Name "dns"
        $requiredFields = @("Primary", "Secondary", "Primary6", "Secondary6")
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $dns.PSObject.Properties) {
            foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName $entry.Name -Entry $entry.Value -RequiredFields $requiredFields)) {
                $invalidEntries.Add($missingField)
            }

            foreach ($field in $requiredFields) {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name $field)) {
                    continue
                }

                try {
                    [System.Net.IPAddress]::Parse([string]$entry.Value.$field) | Out-Null
                } catch {
                    $invalidEntries.Add("$($entry.Name) $field is not a parseable IP address")
                }
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }

    It "contains required feature fields and valid configured functions" {
        $feature = Get-WinUtilConfigObject -Name "feature"
        $functionNames = Get-WinUtilTopLevelFunctionNames
        $requiredFields = @("Content", "category", "panel", "link")
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $feature.PSObject.Properties) {
            foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName $entry.Name -Entry $entry.Value -RequiredFields $requiredFields)) {
                $invalidEntries.Add($missingField)
            }

            if ($entry.Value.Type -and $entry.Value.Type -ne "Button") {
                $invalidEntries.Add("$($entry.Name) has unsupported Type '$($entry.Value.Type)'")
            }

            if ($entry.Value.Type -eq "Button") {
                if (-not $entry.Value.function -and -not $entry.Value.InvokeScript) {
                    $invalidEntries.Add("$($entry.Name) button missing function or InvokeScript")
                }
            } else {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name "Description")) {
                    $invalidEntries.Add("$($entry.Name) missing Description")
                }

                if (-not $entry.Value.feature -and -not $entry.Value.InvokeScript) {
                    $invalidEntries.Add("$($entry.Name) missing feature or InvokeScript action")
                }
            }

            if ($entry.Value.function -and $functionNames -notcontains $entry.Value.function) {
                $invalidEntries.Add("$($entry.Name) references missing function $($entry.Value.function)")
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }

    It "contains required tweak fields and valid action metadata" {
        $tweaks = Get-WinUtilConfigObject -Name "tweaks"
        $requiredFields = @("Content", "category", "panel", "link")
        $allowedTypes = @("Button", "Combobox", "Toggle", "ToggleButton")
        $supportedButtons = Get-WinUtilButtonSwitchNames
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $tweaks.PSObject.Properties) {
            foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName $entry.Name -Entry $entry.Value -RequiredFields $requiredFields)) {
                $invalidEntries.Add($missingField)
            }

            if ($entry.Value.Type -and $allowedTypes -notcontains $entry.Value.Type) {
                $invalidEntries.Add("$($entry.Name) has unsupported Type '$($entry.Value.Type)'")
            }

            if ($entry.Value.Type -eq "Button") {
                if ($supportedButtons -notcontains $entry.Name) {
                    $invalidEntries.Add("$($entry.Name) is not handled by Invoke-WPFButton")
                }
            } elseif ($entry.Value.Type -eq "Combobox") {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name "ComboItems")) {
                    $invalidEntries.Add("$($entry.Name) combobox missing ComboItems")
                }
            } else {
                if (-not (Test-WinUtilHasNonEmptyProperty -Object $entry.Value -Name "Description")) {
                    $invalidEntries.Add("$($entry.Name) missing Description")
                }

                if (-not $entry.Value.registry -and -not $entry.Value.service -and -not $entry.Value.InvokeScript -and -not $entry.Value.appx) {
                    $invalidEntries.Add("$($entry.Name) missing registry, service, InvokeScript, or appx action")
                }
            }

            foreach ($registryEntry in @($entry.Value.registry)) {
                if ($null -eq $registryEntry) { continue }

                foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName "$($entry.Name),registry" -Entry $registryEntry -RequiredFields @("Path", "Name", "Type", "Value", "OriginalValue"))) {
                    $invalidEntries.Add($missingField)
                }
            }

            foreach ($serviceEntry in @($entry.Value.service)) {
                if ($null -eq $serviceEntry) { continue }

                foreach ($missingField in (Get-WinUtilMissingRequiredFields -EntryName "$($entry.Name),service" -Entry $serviceEntry -RequiredFields @("Name", "StartupType", "OriginalType"))) {
                    $invalidEntries.Add($missingField)
                }
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }

    It "defines theme resources required by XAML rendering" {
        $themes = Get-WinUtilConfigObject -Name "themes"
        $invalidEntries = New-Object System.Collections.Generic.List[string]

        foreach ($themeName in @("shared", "Light", "Dark")) {
            if (-not (Test-WinUtilHasProperty -Object $themes -Name $themeName)) {
                $invalidEntries.Add("themes.json missing $themeName")
                continue
            }

            foreach ($property in $themes.$themeName.PSObject.Properties) {
                if ([string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $invalidEntries.Add("$themeName.$($property.Name) is blank")
                }
            }
        }

        $lightKeys = @($themes.Light.PSObject.Properties.Name)
        $darkKeys = @($themes.Dark.PSObject.Properties.Name)
        foreach ($key in $lightKeys) {
            if ($darkKeys -notcontains $key) {
                $invalidEntries.Add("Dark theme missing $key")
            }
        }
        foreach ($key in $darkKeys) {
            if ($lightKeys -notcontains $key) {
                $invalidEntries.Add("Light theme missing $key")
            }
        }

        $xamlText = Get-Content -Path $script:xamlPath -Raw
        $dynamicResourceNames = @(
            [regex]::Matches($xamlText, '\{DynamicResource\s+([^\}\s]+)') |
                ForEach-Object { $_.Groups[1].Value }
        ) | Sort-Object -Unique
        $xamlDefinedResourceNames = @(
            [regex]::Matches($xamlText, 'x:Key="([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value }
        ) | Sort-Object -Unique
        $themeResourceNames = @(
            $themes.shared.PSObject.Properties.Name
            $themes.Light.PSObject.Properties.Name
            $themes.Dark.PSObject.Properties.Name
            "CBorderColor"
            "CButtonBackgroundMouseoverColor"
        ) | Sort-Object -Unique

        foreach ($resourceName in $dynamicResourceNames) {
            if ($xamlDefinedResourceNames -notcontains $resourceName -and $themeResourceNames -notcontains $resourceName) {
                $invalidEntries.Add("XAML DynamicResource '$resourceName' is not defined in themes.json or XAML resources")
            }
        }

        if ($invalidEntries.Count -gt 0) {
            throw ($invalidEntries -join "`n")
        }
    }
}

Describe "Embedded config scripts" {
    It "parse as PowerShell scriptblocks" {
        $invalidScripts = New-Object System.Collections.Generic.List[string]

        foreach ($configFile in (Get-ChildItem -Path $script:configRoot -Filter *.json)) {
            $config = Get-Content -Path $configFile.FullName -Raw | ConvertFrom-Json
            foreach ($entry in $config.PSObject.Properties) {
                foreach ($field in @("InvokeScript", "UndoScript")) {
                    if (-not (Test-WinUtilHasProperty -Object $entry.Value -Name $field)) {
                        continue
                    }

                    $index = 0
                    foreach ($scriptText in @($entry.Value.$field)) {
                        $index++
                        if ([string]::IsNullOrWhiteSpace([string]$scriptText)) {
                            continue
                        }

                        try {
                            [scriptblock]::Create([string]$scriptText) | Out-Null
                        } catch {
                            $invalidScripts.Add("$($configFile.Name):$($entry.Name).$field[$index] $($psitem.Exception.Message)")
                        }
                    }
                }
            }
        }

        if ($invalidScripts.Count -gt 0) {
            throw ($invalidScripts -join "`n")
        }
    }
}
