#requires -Version 5.1
<#
.SYNOPSIS
    Fl3xOptimizer launcher - downloads latest single-file .exe, caches, runs as admin.

.DESCRIPTION
    Designed to be run by end users via a single PowerShell line:

        iwr -useb https://raw.githubusercontent.com/17stck/Fl3xOptimizer/main/launcher.ps1 | iex

    On first run:
      - Downloads the latest single-file .exe from GitHub Releases
      - Caches it at %LOCALAPPDATA%\Fl3xOptimizer\Fl3xOptimizer.exe
      - Launches it with UAC elevation

    On subsequent runs:
      - Just launches the cached exe (instant start)

    Pass -Force to re-download even if already installed.
    Pass -Uninstall to delete the cached file.

.PARAMETER Force
    Re-download even if the app is already installed.

.PARAMETER Uninstall
    Delete the cached install folder.

.EXAMPLE
    iwr -useb https://raw.githubusercontent.com/17stck/Fl3xOptimizer/main/launcher.ps1 | iex
#>

# GitHub repo coordinates
$GitHubUser = '17stck'
$GitHubRepo = 'Fl3xOptimizer'
$ZipName    = 'Fl3xOptimizer.zip'   # Folder-layout zip (NOT single-file - WinUI 3 COM activation breaks in single-file)
$ExeName    = 'Fl3xOptimizer.exe'

# -----------------------------------------------------------------
$AppName     = 'Fl3xOptimizer'
$InstallDir  = Join-Path $env:LOCALAPPDATA $AppName
$ExePath     = Join-Path $InstallDir $ExeName
$VersionFile = Join-Path $InstallDir '.installed-on'

# Parse args even when piped through iex
$ForceUpdate = ($args -contains '-Force')   -or ($MyInvocation.UnboundArguments -contains '-Force')
$Uninstall   = ($args -contains '-Uninstall') -or ($MyInvocation.UnboundArguments -contains '-Uninstall')

# https://github.com/USER/REPO/releases/latest/download/FILE  resolves to the
# newest release automatically - the launcher never needs updating when you
# publish a new version.
$ZipUrl = "https://github.com/$GitHubUser/$GitHubRepo/releases/latest/download/$ZipName"

function Write-Stage($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ---- Uninstall path -----------------------------------------------
if ($Uninstall) {
    if (Test-Path $InstallDir) {
        Write-Stage "Removing $InstallDir ..."
        Remove-Item $InstallDir -Recurse -Force
        Write-Host "Uninstalled." -ForegroundColor Green
    } else {
        Write-Host "Not installed." -ForegroundColor Yellow
    }
    return
}

# ---- Download / update path ---------------------------------------
# Reinstall if anything is missing OR the cached exe is suspiciously small
# (older 50MB single-file approach left some bad caches around).
$needsInstall = $ForceUpdate -or (-not (Test-Path $ExePath))
if (-not $needsInstall -and (Get-Item $ExePath).Length -lt 100KB) {
    Write-Host "Cached exe looks corrupted. Reinstalling..." -ForegroundColor Yellow
    $needsInstall = $true
}

if ($needsInstall) {
    Write-Stage "Downloading $AppName latest release..."
    Write-Host "  $ZipUrl"

    # Kill any running instance first so we can overwrite files
    Get-Process -Name $AppName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 200

    # Wipe old install (clean slate, no leftover broken files)
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    $tempZip = Join-Path $env:TEMP "Fl3xOptimizer-$(Get-Random).zip"

    try {
        # TLS 1.2 needed on older Windows 10 boxes
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        $downloadOk = $false

        # Strategy 1: curl.exe (Windows 10 1803+, Windows 11). Real progress
        # bar that doesn't slow the transfer.
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curl) {
            Write-Host "  Using curl.exe (visible progress)..."
            & $curl.Source -L --progress-bar --fail --retry 3 --retry-delay 2 `
                -A 'Fl3xOptimizer-Launcher' `
                -o $tempZip $ZipUrl
            if ($LASTEXITCODE -eq 0 -and (Test-Path $tempZip) -and (Get-Item $tempZip).Length -gt 10MB) {
                $downloadOk = $true
            } else {
                Write-Host "  curl failed (exit $LASTEXITCODE), trying fallback..." -ForegroundColor Yellow
            }
        }

        # Strategy 2: WebClient (silent but reliable)
        if (-not $downloadOk) {
            Write-Host "  Using WebClient fallback (no progress shown, please wait)..."
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'Fl3xOptimizer-Launcher')
            $wc.DownloadFile($ZipUrl, $tempZip)
            $wc.Dispose()
        }

        if (-not (Test-Path $tempZip) -or (Get-Item $tempZip).Length -lt 10MB) {
            Die "Download did not produce a usable zip at $tempZip"
        }

        Write-Stage "Extracting to $InstallDir ..."
        Expand-Archive -Path $tempZip -DestinationPath $InstallDir -Force
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    } catch {
        Die ("Install failed: " + $_.Exception.Message + "`nCheck that the release zip exists at:`n  $ZipUrl")
    }

    if (-not (Test-Path $ExePath)) {
        Die "Extraction succeeded but $ExePath not found. The release zip may be malformed."
    }

    # Unblock all downloaded files (zone identifier - prevents SmartScreen on every launch)
    Get-ChildItem $InstallDir -Recurse | Unblock-File -ErrorAction SilentlyContinue

    Set-Content -Path $VersionFile -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $exeSize = (Get-Item $ExePath).Length
    $folderSize = (Get-ChildItem $InstallDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host ("Installed: exe={0} KB, total={1:N1} MB at {2}" -f [int]($exeSize/1KB), ($folderSize/1MB), $InstallDir) -ForegroundColor Green
}

# ---- Launch -------------------------------------------------------
Write-Stage "Launching $AppName (you'll see a UAC prompt)..."
try {
    $proc = Start-Process -FilePath $ExePath -Verb RunAs -PassThru
    Write-Host "Started (PID $($proc.Id))." -ForegroundColor Green

    # Verify the process is still alive after 3 seconds. Single-file
    # extraction failures crash within 1-2s, so if it survives 3s the
    # launch succeeded.
    Start-Sleep -Seconds 3
    $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $alive) {
        Write-Host ""
        Write-Host "WARNING: process exited within 3 seconds." -ForegroundColor Yellow
        Write-Host "Common causes:" -ForegroundColor Yellow
        Write-Host "  - Antivirus quarantined the exe (check Defender)" -ForegroundColor Yellow
        Write-Host "  - Corrupted cache - delete and re-run:" -ForegroundColor Yellow
        Write-Host "      Remove-Item `"`$env:LOCALAPPDATA\$AppName`" -Recurse -Force" -ForegroundColor Yellow
        Write-Host "      iwr -useb https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/main/launcher.ps1 | iex" -ForegroundColor Yellow
        Write-Host "  - Missing Windows App SDK runtime (uncommon on Win10 19H1+/Win11)" -ForegroundColor Yellow
    }
} catch {
    Die ("Could not launch: " + $_.Exception.Message)
}
