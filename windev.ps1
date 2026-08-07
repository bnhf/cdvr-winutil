# Compiles this local checkout and runs it - for testing local changes before committing.

$root = $PSScriptRoot
& (Join-Path $root 'Compile.ps1')

$executable = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$currentPowerShell = Join-Path $PSHOME $executable
& $currentPowerShell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $root 'winutil.ps1')
