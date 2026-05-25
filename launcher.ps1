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
$needsInstall = $ForceUpdate -or (-not (Test-Path $ExePath))

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

        # Use WebClient instead of Invoke-WebRequest:
        # PowerShell 5.1's IWR uses the IE engine and renders a progress bar
        # per byte, which drops download speed to ~5 KB/s on an 80 MB file.
        # WebClient.DownloadFile streams at full bandwidth (10+ MB/s).
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Fl3xOptimizer-Launcher')

        # Show simple percent progress without slowing the transfer
        $lastReport = 0
        Register-ObjectEvent -InputObject $wc -EventName DownloadProgressChanged -Action {
            $pct = $Event.SourceEventArgs.ProgressPercentage
            $script:lastReport = $pct
            if ($pct % 10 -eq 0) {
                $mb = [math]::Round($Event.SourceEventArgs.BytesReceived / 1MB, 1)
                $tot = [math]::Round($Event.SourceEventArgs.TotalBytesToReceive / 1MB, 1)
                Write-Host ("  {0,3}%  ({1} / {2} MB)" -f $pct, $mb, $tot)
            }
        } | Out-Null

        $wc.DownloadFile($ExeUrl, $ExePath)
        $wc.Dispose()
        Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue
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
    Start-Process -FilePath $ExePath -Verb RunAs
    Write-Host "Started." -ForegroundColor Green
} catch {
    Die ("Could not launch: " + $_.Exception.Message)
}
