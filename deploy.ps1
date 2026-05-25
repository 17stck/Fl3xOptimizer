#requires -Version 5.1
<#
.SYNOPSIS
    One-shot deploy: authenticate with GitHub, create/sync repo, push launcher,
    create release v1.0, upload Fl3xOptimizer.exe.

    After this script finishes, anyone can run:
        iwr -useb https://raw.githubusercontent.com/17stck/Fl3xOptimizer/main/launcher.ps1 | iex

.PARAMETER Tag
    Release tag (default: auto = v1.0, v1.1, ... based on existing releases)
#>

[CmdletBinding()]
param(
    [string]$Tag = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$root      = $PSScriptRoot
$user      = '17stck'
$repo      = 'Fl3xOptimizer'
$exePath   = Join-Path $root 'publish-singlefile\win-x64\Fl3xOptimizer.exe'
$launcher  = Join-Path $root 'launcher.ps1'

function Write-Stage($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------------
# 1. Ensure gh CLI is installed + on PATH
# --------------------------------------------------------------------
Write-Stage "Checking GitHub CLI..."
$ghPaths = @(
    'C:\Program Files\GitHub CLI\gh.exe',
    'C:\Program Files (x86)\GitHub CLI\gh.exe'
)
$gh = $null
foreach ($p in $ghPaths) { if (Test-Path $p) { $gh = $p; break } }
if (-not $gh) { $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source }

if (-not $gh) {
    Write-Host "  Installing GitHub CLI via winget..."
    & winget install --id GitHub.cli --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    foreach ($p in $ghPaths) { if (Test-Path $p) { $gh = $p; break } }
    if (-not $gh) { Die "GitHub CLI install failed. Install manually from https://cli.github.com/" }
}
Write-Host "  gh: $gh"

# Add to PATH for the rest of the session
$env:Path = (Split-Path $gh) + ";$env:Path"

# --------------------------------------------------------------------
# 2. Authenticate (opens browser - one-time only)
# --------------------------------------------------------------------
Write-Stage "Checking GitHub auth..."
$authStatus = & $gh auth status 2>&1 | Out-String
if ($authStatus -match 'Logged in to github.com') {
    Write-Host "  Already authenticated."
} else {
    Write-Host "  Not authenticated. Starting browser login..." -ForegroundColor Yellow
    Write-Host "  When the browser opens:" -ForegroundColor Yellow
    Write-Host "    1. Sign in to GitHub as '$user'" -ForegroundColor Yellow
    Write-Host "    2. Approve the device code shown in this terminal" -ForegroundColor Yellow
    & $gh auth login --web --git-protocol https --hostname github.com --scopes 'repo,workflow'
    if ($LASTEXITCODE -ne 0) { Die "gh auth login failed" }
}

# --------------------------------------------------------------------
# 3. Create the repo if it doesn't exist
# --------------------------------------------------------------------
Write-Stage "Checking repo $user/$repo on GitHub..."
& $gh repo view "$user/$repo" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Repo doesn't exist - creating PUBLIC repo..."
    & $gh repo create "$user/$repo" --public --description "Windows + FiveM optimizer (WinUI 3 / .NET 8)" --confirm 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { Die "Failed to create repo" }
} else {
    Write-Host "  Repo exists."
}

# --------------------------------------------------------------------
# 4. Configure remote + push (launcher.ps1 only)
# --------------------------------------------------------------------
Write-Stage "Pushing launcher.ps1 to main branch..."
Set-Location $root

$existingRemote = & git remote get-url origin 2>$null
if ($LASTEXITCODE -ne 0) {
    & git remote add origin "https://github.com/$user/$repo.git" 2>&1 | Out-String | Write-Host
} else {
    & git remote set-url origin "https://github.com/$user/$repo.git" 2>&1 | Out-String | Write-Host
}

# git uses gh's stored credential helper now
& git push -u origin main 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Die "git push failed - check 'git status' and credential setup" }
Write-Host "  Pushed."

# --------------------------------------------------------------------
# 5. Verify single-file exe exists
# --------------------------------------------------------------------
Write-Stage "Verifying release artifact..."
if (-not (Test-Path $exePath)) {
    Write-Host "  Single-file exe not found at: $exePath" -ForegroundColor Yellow
    Write-Host "  Building it now..."
    & (Join-Path $root 'publish-singlefile.ps1') -Runtime win-x64
    if ($LASTEXITCODE -ne 0) { Die "publish-singlefile.ps1 failed" }
}
$exeSize = (Get-Item $exePath).Length
Write-Host ("  Exe: {0} ({1:N2} MB)" -f $exePath, ($exeSize / 1MB))

# --------------------------------------------------------------------
# 6. Determine next release tag
# --------------------------------------------------------------------
if (-not $Tag) {
    Write-Stage "Determining next release tag..."
    $releases = & $gh release list --repo "$user/$repo" --limit 50 2>$null
    $existingTags = @()
    if ($LASTEXITCODE -eq 0 -and $releases) {
        $existingTags = $releases | ForEach-Object {
            ($_ -split '\s+')[1]
        } | Where-Object { $_ -match '^v\d+\.\d+' }
    }
    if ($existingTags.Count -eq 0) {
        $Tag = 'v1.0'
    } else {
        # bump minor version of highest existing tag
        $latest = $existingTags | Sort-Object -Descending { [version]($_ -replace '^v','') } | Select-Object -First 1
        $ver = [version]($latest -replace '^v','')
        $Tag = "v{0}.{1}" -f $ver.Major, ($ver.Minor + 1)
    }
    Write-Host "  Next tag: $Tag"
}

# --------------------------------------------------------------------
# 7. Create release + upload exe
# --------------------------------------------------------------------
Write-Stage "Creating release $Tag and uploading Fl3xOptimizer.exe..."
$title = "Fl3xOptimizer $Tag"
$notes = "Single-file self-extracting build.`n`nInstall + run:`n`n``````powershell`niwr -useb https://raw.githubusercontent.com/$user/$repo/main/launcher.ps1 | iex`n```````n`nOr direct download: [Fl3xOptimizer.exe](https://github.com/$user/$repo/releases/latest/download/Fl3xOptimizer.exe)"

& $gh release create $Tag $exePath `
    --repo "$user/$repo" `
    --title $title `
    --notes $notes 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Die "gh release create failed (tag may already exist - try a different -Tag)" }

# --------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------
Write-Host ""
Write-Host "================ DEPLOY COMPLETE ================" -ForegroundColor Green
Write-Host "Repo    : https://github.com/$user/$repo"
Write-Host "Release : https://github.com/$user/$repo/releases/tag/$Tag"
Write-Host ""
Write-Host "Send this to your friend:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  iwr -useb https://raw.githubusercontent.com/$user/$repo/main/launcher.ps1 | iex" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host ""
Write-Host "================================================="
