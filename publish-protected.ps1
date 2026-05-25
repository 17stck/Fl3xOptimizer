#requires -Version 5.1
<#
.SYNOPSIS
    Build, obfuscate, and package Fl3xOptimizer for distribution.

.DESCRIPTION
    1. Cleans previous publish output.
    2. Publishes Release win-x64 self-contained (folder layout, no single-file,
       no ReadyToRun so Obfuscar has a pure-IL DLL on disk to process).
       ReadyToRun is disabled because it produces mixed-mode (IL + native)
       assemblies that Mono.Cecil/Obfuscar cannot rewrite.
    3. Runs Obfuscar on Fl3xOptimizer.dll. Renames internal symbols,
       encrypts strings, strips method names.
    4. Replaces the original DLL with the obfuscated one.
    5. Optionally zips the folder for transfer.

.PARAMETER Runtime
    win-x64 (default) | win-x86 | win-arm64

.PARAMETER Zip
    Also create a .zip of the final folder.

.EXAMPLE
    .\publish-protected.ps1
    .\publish-protected.ps1 -Runtime win-x64 -Zip
#>

[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-x86','win-arm64')]
    [string]$Runtime = 'win-x64',

    [switch]$Zip
)

Set-StrictMode -Version Latest
# Don't stop on stderr from native commands (dotnet/obfuscar write warnings
# to stderr routinely). We check $LASTEXITCODE explicitly after each call.
$ErrorActionPreference = 'Continue'

$root      = $PSScriptRoot
$proj      = Join-Path $root 'Fl3xOptimizer\Fl3xOptimizer.csproj'
$stageDir  = Join-Path $root "publish-staging\$Runtime"
$finalDir  = Join-Path $root "publish-protected\$Runtime"
$obfConfig = Join-Path $root 'Obfuscar.xml'
$obfOutDir = Join-Path $stageDir 'Obfuscator'  # Obfuscar's default output subdir

function Write-Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg)       { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------------
# 0. Ensure Obfuscar global tool is installed
# --------------------------------------------------------------------
Write-Step "Checking Obfuscar tool..."
$obfTool = Get-Command 'obfuscar.console' -ErrorAction SilentlyContinue
if (-not $obfTool) {
    Write-Host "Obfuscar not found - installing as a global .NET tool..."
    & dotnet tool install --global Obfuscar.GlobalTool 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { Fail "dotnet tool install failed (exit $LASTEXITCODE)" }

    # Refresh PATH for the current session
    $toolsDir = Join-Path $env:USERPROFILE '.dotnet\tools'
    $env:Path = "$toolsDir;$env:Path"
    $obfTool = Get-Command 'obfuscar.console' -ErrorAction SilentlyContinue
    if (-not $obfTool) { Fail "Obfuscar still not on PATH after install. Open a new terminal." }
}
Write-Host "  Obfuscar: $($obfTool.Source)"

# --------------------------------------------------------------------
# 1. Clean previous output
# --------------------------------------------------------------------
Write-Step "Cleaning previous publish output..."
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
if (Test-Path $finalDir) { Remove-Item -Recurse -Force $finalDir }

# --------------------------------------------------------------------
# 2. Publish Release (folder layout, NOT single-file)
# --------------------------------------------------------------------
Write-Step "Publishing Release $Runtime to staging..."
& dotnet publish $proj `
    -c Release `
    -r $Runtime `
    --self-contained true `
    /p:PublishSingleFile=false `
    /p:PublishReadyToRun=false `
    /p:PublishTrimmed=false `
    /p:DebugType=none `
    /p:DebugSymbols=false `
    /p:WindowsPackageType=None `
    /p:WindowsAppSDKSelfContained=true `
    /p:EnableMsixTooling=true `
    -o $stageDir `
    -v minimal `
    -nologo 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Fail "dotnet publish failed (exit $LASTEXITCODE)" }

$mainDll = Join-Path $stageDir 'Fl3xOptimizer.dll'
if (-not (Test-Path $mainDll)) { Fail "Main DLL not found: $mainDll" }
$beforeSize = (Get-Item $mainDll).Length
Write-Host ("  Built Fl3xOptimizer.dll  ({0:N0} bytes)" -f $beforeSize)

# --------------------------------------------------------------------
# 3. Run Obfuscar - substitute InPath/OutPath into a temp config
# --------------------------------------------------------------------
Write-Step "Running Obfuscar on Fl3xOptimizer.dll..."

$tempConfig = New-TemporaryFile
$cfgXml = (Get-Content $obfConfig -Raw) `
    -replace '<Var name="InPath" value="[^"]+" />',  ('<Var name="InPath" value="'  + $stageDir + '" />') `
    -replace '<Var name="OutPath" value="[^"]+" />', ('<Var name="OutPath" value="' + $obfOutDir + '" />')
Set-Content -Path $tempConfig.FullName -Value $cfgXml -Encoding utf8

try {
    & obfuscar.console $tempConfig.FullName 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { Fail "Obfuscar failed (exit $LASTEXITCODE)" }
} finally {
    Remove-Item $tempConfig.FullName -ErrorAction SilentlyContinue
}

$obfDll = Join-Path $obfOutDir 'Fl3xOptimizer.dll'
if (-not (Test-Path $obfDll)) { Fail "Obfuscated DLL not produced: $obfDll" }
$afterSize = (Get-Item $obfDll).Length
Write-Host ("  Obfuscated DLL          ({0:N0} bytes)" -f $afterSize)

# --------------------------------------------------------------------
# 4. Replace original DLL, copy staging to final
# --------------------------------------------------------------------
Write-Step "Replacing original DLL with obfuscated version..."
Copy-Item -Path $obfDll -Destination $mainDll -Force

# Remove the Obfuscator subdir + any *.pdb that slipped through
if (Test-Path $obfOutDir) { Remove-Item -Recurse -Force $obfOutDir }
Get-ChildItem $stageDir -Recurse -Filter '*.pdb' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

Write-Step "Copying to final publish folder..."
New-Item -ItemType Directory -Force -Path $finalDir | Out-Null
Copy-Item -Path (Join-Path $stageDir '*') -Destination $finalDir -Recurse -Force

# --------------------------------------------------------------------
# 5. Optional zip
# --------------------------------------------------------------------
if ($Zip) {
    Write-Step "Creating .zip archive..."
    $zipPath = Join-Path $root "Fl3xOptimizer-$Runtime-protected.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $finalDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host ("  Wrote {0}" -f $zipPath)
}

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------
Write-Host ""
Write-Host "================ PROTECTED BUILD COMPLETE ================" -ForegroundColor Green
Write-Host "Output folder : $finalDir"
Write-Host "Entry point   : $(Join-Path $finalDir 'Fl3xOptimizer.exe')"
Write-Host "DLL size      : $afterSize bytes (was $beforeSize before obfuscation)"
Write-Host ""
Write-Host "Verify protection by opening Fl3xOptimizer.dll in ILSpy:"
Write-Host "  - Service classes should appear as a.b(), _0001, etc."
Write-Host "  - String literals should be encrypted (decoded at runtime)"
Write-Host "  - Page classes are intentionally readable (WinUI XAML needs them)"
Write-Host "=========================================================="
