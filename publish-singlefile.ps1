#requires -Version 5.1
<#
.SYNOPSIS
    Build, obfuscate, and produce a SINGLE .exe file (no zip) for distribution.

.DESCRIPTION
    Workflow:
      1. dotnet build to a staging folder (folder layout, NOT single-file)
      2. Obfuscar rewrites Fl3xOptimizer.dll in place
      3. dotnet publish --no-build /p:PublishSingleFile=true bundles
         the obfuscated DLL + all native deps + .NET runtime into one .exe
         (auto-extracts to %TEMP%\.net\<hash>\ on first run)

    Output: single .exe ready to upload to GitHub Releases.
    Friend just clicks the download link, double-clicks the .exe, and the
    app opens. No zip, no extraction, no PowerShell required.

    Size: roughly 80-90 MB (compressed self-extracting bundle).

.PARAMETER Runtime
    win-x64 (default) | win-x86 | win-arm64
#>

[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-x86','win-arm64')]
    [string]$Runtime = 'win-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$root      = $PSScriptRoot
$proj      = Join-Path $root 'Fl3xOptimizer\Fl3xOptimizer.csproj'
$tfm       = 'net8.0-windows10.0.19041.0'
$binDir    = Join-Path $root "Fl3xOptimizer\bin\Release\$tfm\$Runtime"
$finalDir  = Join-Path $root "publish-singlefile\$Runtime"
$obfConfig = Join-Path $root 'Obfuscar.xml'
$obfOutDir = Join-Path $binDir 'Obfuscator'

function Write-Stage($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------------
# 0. Verify Obfuscar
# --------------------------------------------------------------------
Write-Stage "Checking Obfuscar tool..."
$obfTool = Get-Command 'obfuscar.console' -ErrorAction SilentlyContinue
if (-not $obfTool) {
    $toolsDir = Join-Path $env:USERPROFILE '.dotnet\tools'
    $env:Path = "$toolsDir;$env:Path"
    $obfTool = Get-Command 'obfuscar.console' -ErrorAction SilentlyContinue
    if (-not $obfTool) { Die "Obfuscar not installed. Run: dotnet tool install --global Obfuscar.GlobalTool" }
}
Write-Host "  Obfuscar: $($obfTool.Source)"

# --------------------------------------------------------------------
# 1. Clean previous output
# --------------------------------------------------------------------
Write-Stage "Cleaning previous output..."
if (Test-Path $binDir)   { Remove-Item -Recurse -Force $binDir }
if (Test-Path $finalDir) { Remove-Item -Recurse -Force $finalDir }

# --------------------------------------------------------------------
# 2. Build to bin (no publish, no single-file yet)
# --------------------------------------------------------------------
Write-Stage "Building Release $Runtime..."
& dotnet build $proj `
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
    -v minimal `
    -nologo 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Die "dotnet build failed (exit $LASTEXITCODE)" }

$mainDll = Join-Path $binDir 'Fl3xOptimizer.dll'
if (-not (Test-Path $mainDll)) { Die "Main DLL not found: $mainDll" }
$beforeSize = (Get-Item $mainDll).Length
Write-Host ("  Built Fl3xOptimizer.dll  ({0:N0} bytes)" -f $beforeSize)

# --------------------------------------------------------------------
# 3. Obfuscate Fl3xOptimizer.dll in bin
# --------------------------------------------------------------------
Write-Stage "Running Obfuscar on Fl3xOptimizer.dll..."

$tempConfig = New-TemporaryFile
$cfgXml = (Get-Content $obfConfig -Raw) `
    -replace '<Var name="InPath" value="[^"]+" />',  ('<Var name="InPath" value="'  + $binDir + '" />') `
    -replace '<Var name="OutPath" value="[^"]+" />', ('<Var name="OutPath" value="' + $obfOutDir + '" />')
Set-Content -Path $tempConfig.FullName -Value $cfgXml -Encoding utf8

try {
    & obfuscar.console $tempConfig.FullName 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { Die "Obfuscar failed (exit $LASTEXITCODE)" }
} finally {
    Remove-Item $tempConfig.FullName -ErrorAction SilentlyContinue
}

$obfDll = Join-Path $obfOutDir 'Fl3xOptimizer.dll'
if (-not (Test-Path $obfDll)) { Die "Obfuscated DLL not produced: $obfDll" }
$afterSize = (Get-Item $obfDll).Length
Write-Host ("  Obfuscated DLL          ({0:N0} bytes)" -f $afterSize)

# Replace original DLL in bin/Release with obfuscated version
# so that the upcoming publish --no-build bundles the obfuscated one.
Copy-Item -Path $obfDll -Destination $mainDll -Force
Remove-Item -Recurse -Force $obfOutDir

# --------------------------------------------------------------------
# 4. Publish single-file using --no-build (reuse the obfuscated DLL)
# --------------------------------------------------------------------
Write-Stage "Bundling into single self-extracting .exe..."
& dotnet publish $proj `
    -c Release `
    -r $Runtime `
    --self-contained true `
    --no-build `
    /p:PublishSingleFile=true `
    /p:IncludeNativeLibrariesForSelfExtract=true `
    /p:EnableCompressionInSingleFile=true `
    /p:PublishReadyToRun=false `
    /p:PublishTrimmed=false `
    /p:DebugType=none `
    /p:DebugSymbols=false `
    /p:WindowsPackageType=None `
    /p:WindowsAppSDKSelfContained=true `
    /p:EnableMsixTooling=true `
    -o $finalDir `
    -v minimal `
    -nologo 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Die "dotnet publish failed (exit $LASTEXITCODE)" }

# --------------------------------------------------------------------
# 5. Strip everything except the single .exe
# --------------------------------------------------------------------
Write-Stage "Cleaning bundle folder..."
$finalExe = Join-Path $finalDir 'Fl3xOptimizer.exe'
if (-not (Test-Path $finalExe)) { Die "Single-file exe not produced: $finalExe" }

# Move .exe to root, delete everything else
$tmpExe = Join-Path $root "Fl3xOptimizer-$Runtime.exe.tmp"
Move-Item $finalExe $tmpExe -Force
Remove-Item $finalDir -Recurse -Force
New-Item -ItemType Directory -Force -Path $finalDir | Out-Null
Move-Item $tmpExe (Join-Path $finalDir 'Fl3xOptimizer.exe') -Force

$exeSize = (Get-Item (Join-Path $finalDir 'Fl3xOptimizer.exe')).Length

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------
Write-Host ""
Write-Host "================ SINGLE-FILE BUILD COMPLETE ================" -ForegroundColor Green
Write-Host "Single .exe   : $(Join-Path $finalDir 'Fl3xOptimizer.exe')"
Write-Host ("Size          : {0:N2} MB" -f ($exeSize / 1MB))
Write-Host ""
Write-Host "Upload this .exe to a GitHub Release."
Write-Host "Friend can:"
Write-Host "  1. Click the direct download link, double-click .exe"
Write-Host "  2. Or use the PowerShell launcher (downloads + runs)"
Write-Host "==========================================================="
