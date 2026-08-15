#===========================================================================
# Tests - Optimize-WinUtilSlmBat (patches slm.bat for speed and stdin safety)
#===========================================================================

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    . (Join-Path $script:repoRoot "functions\private\Optimize-WinUtilSlmBat.ps1")

    function Write-WinUtilLog { param($Message, $Level, $Component) }

    # A trimmed-down but representative slice of slm.bat's own real source - just enough of each
    # targeted line, in context, to prove the substitutions apply correctly without depending on
    # the rest of the (much longer) real script.
    $script:realSlmBatSlice = @'
:download
echo Downloading Streaming Library Manager files...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%link%' -OutFile '%outfile%'"
timeout /NOBREAK /T 5

echo Extracting Streaming Library Manager files...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath .\%outfile%"
timeout /NOBREAK /T 5

echo Please wait...
timeout /NOBREAK /T 5
del /f "%temp_batch%"
'@
}

Describe "Optimize-WinUtilSlmBat" {
    BeforeEach {
        Mock Write-WinUtilLog { }
        $script:capturedContent = $null
        Mock Set-Content {
            $script:capturedContent = $Value
        }
    }

    It "disables Invoke-WebRequest's live progress bar" {
        Mock Get-Content { $script:realSlmBatSlice }

        Optimize-WinUtilSlmBat -Path "C:\fake\slm.bat"

        $script:capturedContent | Should -Match ([regex]::Escape("`$ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri '%link%' -OutFile '%outfile%'"))
    }

    It "replaces Expand-Archive with ZipFile.ExtractToDirectory, extracting to the same 'slm' folder" {
        Mock Get-Content { $script:realSlmBatSlice }

        Optimize-WinUtilSlmBat -Path "C:\fake\slm.bat"

        $script:capturedContent | Should -Match ([regex]::Escape("[System.IO.Compression.ZipFile]::ExtractToDirectory('%outfile%', 'slm')"))
        $script:capturedContent | Should -Match ([regex]::Escape("Add-Type -AssemblyName System.IO.Compression.FileSystem"))
        $script:capturedContent | Should -Not -Match ([regex]::Escape("Expand-Archive -LiteralPath .\%outfile%"))
    }

    It "replaces every occurrence of the stdin-fragile timeout wait, not just the first" {
        # Regression guard for the actual reported bug: slm.bat's "port" command feeds this
        # exact wait after its own elevated netsh call, and timeout.exe hard-refuses to run at
        # all when stdin is redirected (needed to answer "port"'s interactive prompt
        # non-interactively) - "ERROR: Input redirection is not supported, exiting the process
        # immediately." confirmed live in the install log. ping doesn't touch stdin at all.
        Mock Get-Content { $script:realSlmBatSlice }

        Optimize-WinUtilSlmBat -Path "C:\fake\slm.bat"

        $script:capturedContent | Should -Not -Match "timeout /NOBREAK /T 5"
        (@($script:capturedContent -split "`n") | Where-Object { $_ -match "ping -n 6 127\.0\.0\.1 >nul" }).Count | Should -Be 3
    }

    It "returns `$true and writes the file when the expected text is found" {
        Mock Get-Content { $script:realSlmBatSlice }

        $result = Optimize-WinUtilSlmBat -Path "C:\fake\slm.bat"

        $result | Should -Be $true
        Should -Invoke -CommandName Set-Content -Times 1 -Exactly -ParameterFilter { $Path -eq "C:\fake\slm.bat" }
    }

    It "returns `$false, warns, and does not write the file when upstream's text has changed" {
        Mock Get-Content { "echo upstream rewrote this script entirely`r`n" }

        $result = Optimize-WinUtilSlmBat -Path "C:\fake\slm.bat"

        $result | Should -Be $false
        Should -Invoke -CommandName Set-Content -Times 0 -Exactly
        Should -Invoke -CommandName Write-WinUtilLog -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" }
    }

    It "returns `$false and logs a warning instead of throwing when reading the file fails" {
        Mock Get-Content { throw "access denied" }

        { Optimize-WinUtilSlmBat -Path "C:\fake\slm.bat" } | Should -Not -Throw
        $result = Optimize-WinUtilSlmBat -Path "C:\fake\slm.bat"

        $result | Should -Be $false
        Should -Invoke -CommandName Write-WinUtilLog -Times 2 -Exactly -ParameterFilter { $Level -eq "WARN" }
    }
}
