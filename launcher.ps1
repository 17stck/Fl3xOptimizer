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
$ExeUrl = "https://github.com/$GitHubUser/$GitHubRepo/releases/latest/download/$ExeName"

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
# Minimum sane size: the real exe is ~82 MB. Anything under 50 MB is a
# partial download from an aborted run - re-download it.
$MinSizeBytes = 50MB
$cachedSize = if (Test-Path $ExePath) { (Get-Item $ExePath).Length } else { 0 }
$tooSmall = ($cachedSize -gt 0) -and ($cachedSize -lt $MinSizeBytes)
if ($tooSmall) {
    Write-Host ("Cached file looks incomplete ({0:N1} MB < 50 MB). Re-downloading..." -f ($cachedSize / 1MB)) -ForegroundColor Yellow
}
$needsInstall = $ForceUpdate -or (-not (Test-Path $ExePath)) -or $tooSmall

if ($needsInstall) {
    Write-Stage "Downloading $AppName latest release..."
    Write-Host "  $ExeUrl"

    # Kill any running instance first so we can overwrite the file
    Get-Process -Name $AppName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 200

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }

    try {
        # TLS 1.2 needed on older Windows 10 boxes
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        $downloadOk = $false

        # Strategy 1: curl.exe (Windows 10 1803+, Windows 11). Has a real
        # progress bar that does NOT slow the transfer down (unlike IWR).
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curl) {
            Write-Host "  Using curl.exe (built-in, visible progress)..."
            & $curl.Source -L --progress-bar --fail --retry 3 --retry-delay 2 `
                -A 'Fl3xOptimizer-Launcher' `
                -o $ExePath $ExeUrl
            if ($LASTEXITCODE -eq 0 -and (Test-Path $ExePath) -and (Get-Item $ExePath).Length -gt $MinSizeBytes) {
                $downloadOk = $true
            } else {
                Write-Host "  curl failed (exit $LASTEXITCODE), trying fallback..." -ForegroundColor Yellow
            }
        }

        # Strategy 2: Start-BitsTransfer (built-in, Windows 7+). Native
        # Windows download manager — fast, resumable, native progress UI.
        if (-not $downloadOk -and (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
            Write-Host "  Using BITS transfer..."
            try {
                Import-Module BitsTransfer -ErrorAction Stop
                Start-BitsTransfer -Source $ExeUrl -Destination $ExePath -DisplayName 'Fl3xOptimizer' -Description 'Downloading release...'
                if ((Test-Path $ExePath) -and (Get-Item $ExePath).Length -gt $MinSizeBytes) {
                    $downloadOk = $true
                }
            } catch {
                Write-Host "  BITS failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Strategy 3: WebClient (no progress but reliable, last resort)
        if (-not $downloadOk) {
            Write-Host "  Using WebClient fallback (no progress shown, please wait)..."
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'Fl3xOptimizer-Launcher')
            $wc.DownloadFile($ExeUrl, $ExePath)
            $wc.Dispose()
            $downloadOk = $true
        }
    } catch {
        Die ("Download failed: " + $_.Exception.Message + "`nCheck that the release + exe exist at:`n  $ExeUrl")
    }

    if (-not (Test-Path $ExePath)) {
        Die "Download succeeded but $ExePath not found."
    }

    # Unblock the file so SmartScreen doesn't prompt every launch
    try { Unblock-File -Path $ExePath -ErrorAction SilentlyContinue } catch {}

    Set-Content -Path $VersionFile -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $exeSize = (Get-Item $ExePath).Length
    Write-Host ("Installed ({0:N2} MB)." -f ($exeSize / 1MB)) -ForegroundColor Green
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
