# This script downloads everything into whatever folder IT lives in - so
# for a fresh install, copy just this one file into an empty folder first
# and run it from there (don't run it from inside tools/, since manifest
# entries under tools/ are skipped and you'd end up nested one level in).
# ==========================================================
# DOWNLOADER (standalone - no Python, git, or GitHub account needed)
#
# Use this to grab the app onto a machine that doesn't have it yet, or to
# force an update without launching the app first. Run it from wherever
# you want the project folder to live (an empty folder, or an existing
# install to update in place).
#
# This is the bootstrap counterpart to app/updater.py: once the app is
# running, IT checks for and applies updates itself (see the "Check for
# updates" link / banner in the GUI). This script exists for the "don't
# have it running yet at all" case, same role the old downloader.ps1 had.
# ==========================================================

# ---- CONFIG: same repo/branch as app/updater.py -----------------
$repoUser = "glutton780-svg"
$repoName = "Macro-hub"
$branch   = "main"
# -------------------------------------------------------------------

$localDir    = $PSScriptRoot
$baseUrl     = "https://raw.githubusercontent.com/$repoUser/$repoName/$branch/latest"
$versionFile = Join-Path $localDir "VERSION"

try {
    $remoteVersion = (Invoke-WebRequest -Uri "$baseUrl/version.txt" -UseBasicParsing).Content.Trim()
} catch {
    Write-Host "Could not reach GitHub. Check your internet connection."
    pause
    exit
}

$localVersion = ""
if (Test-Path $versionFile) {
    $localVersion = (Get-Content $versionFile -Raw).Trim()
}

if ($remoteVersion -eq $localVersion) {
    Write-Host "Already up to date (version $localVersion)."
    pause
    exit
}

Write-Host "New version found: $remoteVersion (you have: $localVersion)"
Write-Host "Fetching file list..."

try {
    $manifestJson = (Invoke-WebRequest -Uri "$baseUrl/manifest.json" -UseBasicParsing).Content
    $manifest = $manifestJson | ConvertFrom-Json
} catch {
    Write-Host "Could not fetch manifest.json from GitHub."
    pause
    exit
}

# Never clobber your own local data/config, same list app/updater.py protects.
$protectedFiles = @("settings.json", "VERSION", "server_capture.png")
$protectedDirs  = @("__pycache__", ".git", "dist", "build", "data", "tools")

Write-Host "Downloading $($manifest.Count) files..."
foreach ($relPath in $manifest) {
    $norm = $relPath -replace '\\', '/'
    $parts = $norm -split '/'
    if ($protectedFiles -contains $parts[-1]) { continue }
    if ($protectedDirs -contains $parts[0]) { continue }

    $dest = Join-Path $localDir ($norm -replace '/', [IO.Path]::DirectorySeparatorChar)
    $destDir = Split-Path $dest
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Invoke-WebRequest -Uri "$baseUrl/$norm" -OutFile $dest
}

Set-Content -Path $versionFile -Value $remoteVersion
Write-Host ""
Write-Host "Done - updated to version $remoteVersion."
Write-Host "Run build.bat (or 'python main.py') to use it."
pause
