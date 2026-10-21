param(
    # Run with -Reconfigure (or delete uploader.config.json) to pick a different repo.
    [switch]$Reconfigure
)

# ==========================================================
# UPLOADER (dev-side only - NOT shipped in the built .exe)
#
# Works with ANY repo. The first time you run it, it asks which repo
# to publish to and remembers the answer in uploader.config.json (next
# to your project files). To switch repos later: delete that file, or
# run the script with -Reconfigure.
#
# On every run it makes sure:
#   1. Git is installed (installs it with winget if missing)
#   2. Git knows who you are (asks once, remembers)
#   3. You are signed in to the repo's host (opens the browser login)
#   4. This folder is attached to the repo (auto git init/fetch/reset)
# ...then does the usual: bump version, mirror the project into
# latest/, write manifest.json + version.txt, commit, push.
#
# Works whether this script sits in the project root OR in a "tools"
# subfolder of it.
# ==========================================================

$latestFolder = "latest"
$configName   = "uploader.config.json"

$excludeDirs  = @(".git", "__pycache__", $latestFolder, "tools", "dist", "build", "data")
$excludeFiles = @("settings.json", "VERSION", "server_capture.png", "applog.txt", $configName)

function Stop-Script($msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Write-Host ""
    pause
    exit 1
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
    foreach ($p in @("$env:ProgramFiles\Git\cmd", "${env:ProgramFiles(x86)}\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")) {
        if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) { $env:Path += ";$p" }
    }
}

function Test-Git {
    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

# Accepts "owner/repo", "https://github.com/owner/repo(.git)", or an
# ssh/other-host URL. Returns a clone URL, or $null if it's not usable.
function Resolve-RepoUrl($text) {
    $t = "$text".Trim().TrimEnd('/')
    if ($t -match '^[\w.-]+/[\w.-]+$') {
        if ($t -notmatch '\.git$') { $t += ".git" }
        return "https://github.com/$t"
    }
    if ($t -match '^(https?://|git@|ssh://)') {
        if (($t -match 'github\.com') -and ($t -notmatch '\.git$')) { $t += ".git" }
        return $t
    }
    return $null
}

function Get-NormalizedUrl($u) {
    return (("$u".Trim() -replace '\.git$', '').TrimEnd('/')).ToLower()
}

# Short "owner/repo" label for messages.
function Get-RepoLabel($u) {
    if ("$u" -match '[:/]([^/:]+)/([^/]+?)(\.git)?/?$') { return "$($Matches[1])/$($Matches[2])" }
    return "$u"
}

# ----------------------------------------------------------
# Step 0: figure out the project root
# ----------------------------------------------------------
if ((Split-Path $PSScriptRoot -Leaf) -ieq "tools") {
    $root = Split-Path $PSScriptRoot -Parent
} else {
    $root = $PSScriptRoot
}
Set-Location $root
Write-Host "Project root: $root"

# ----------------------------------------------------------
# Step 1: make sure Git is installed
# ----------------------------------------------------------
if (-not (Test-Git)) {
    Update-SessionPath
}
if (-not (Test-Git)) {
    Write-Host "Git isn't installed - trying to install it automatically (accept the Windows prompt if one appears)..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
        Update-SessionPath
    }
    # Fallback: winget missing or failed - download the official Git
    # for Windows installer from GitHub and run it silently.
    if (-not (Test-Git)) {
        Write-Host "winget didn't work - downloading the Git installer directly..."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers @{ "User-Agent" = "uploader-script" }
            if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $pattern = "Git-*-arm64.exe" } else { $pattern = "Git-*-64-bit.exe" }
            $asset = $release.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
            if (-not $asset) { throw "no matching installer found in the latest release" }
            $installer = Join-Path $env:TEMP $asset.name
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing
            Write-Host "Installing Git (accept the Windows prompt if one appears)..."
            Start-Process -FilePath $installer -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP-" -Wait
            Remove-Item $installer -Force -ErrorAction SilentlyContinue
            Update-SessionPath
        } catch {
            Write-Host "Direct download failed: $_"
        }
    }
    if (-not (Test-Git)) {
        Start-Process "https://git-scm.com/download/win"
        Stop-Script "Couldn't install Git automatically. I opened the download page - install it (default options are fine), then run this again."
    }
    Write-Host "Git installed."
}

# ----------------------------------------------------------
# Step 2: make sure Git knows who you are (needed to commit)
# ----------------------------------------------------------
$gitName  = git config --get user.name
$gitEmail = git config --get user.email

if (-not $gitName) {
    $gitName = Read-Host "First-time setup - what name should show on your commits"
    if (-not $gitName) { $gitName = $env:USERNAME }
    git config --global user.name "$gitName"
}
if (-not $gitEmail) {
    $gitEmail = Read-Host "Email for commits (press Enter to use a placeholder no-reply address)"
    if (-not $gitEmail) { $gitEmail = "$($env:USERNAME)@users.noreply.github.com" }
    git config --global user.email "$gitEmail"
}

# ----------------------------------------------------------
# Step 3: decide which repo to publish to
#   saved config  ->  existing git remote  ->  ask
# ----------------------------------------------------------
$configPath = Join-Path $root $configName
$RemoteUrl  = $null
$Branch     = $null

if ((Test-Path $configPath) -and (-not $Reconfigure)) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $RemoteUrl = $cfg.remoteUrl
        $Branch    = $cfg.branch
    } catch {
        Write-Host "Couldn't read $configName - I'll ask again."
    }
}

if ((-not $RemoteUrl) -and (-not $Reconfigure) -and (Test-Path ".git")) {
    $origin = git remote get-url origin 2>$null
    if (($LASTEXITCODE -eq 0) -and $origin) {
        $RemoteUrl = "$origin".Trim()
        $b = git rev-parse --abbrev-ref HEAD 2>$null
        if (($LASTEXITCODE -eq 0) -and $b -and ($b -ne "HEAD")) { $Branch = "$b".Trim() }
        Write-Host "Using this folder's existing git remote: $RemoteUrl"
    }
}

while (-not $RemoteUrl) {
    $answer = Read-Host "Which repo should this publish to? (e.g. owner/repo, or a full URL)"
    $RemoteUrl = Resolve-RepoUrl $answer
    if (-not $RemoteUrl) {
        Write-Host "That doesn't look like a repo - try 'owner/repo' or a full https:// URL."
    }
}
$RepoLabel = Get-RepoLabel $RemoteUrl

# ----------------------------------------------------------
# Step 4: make sure you're signed in / have access
#
# Git for Windows ships with Git Credential Manager, which opens a
# browser sign-in window the first time it's needed and remembers the
# login afterward. We trigger that here, up front, so you sign in
# BEFORE anything gets built rather than failing at the very end.
# ----------------------------------------------------------
if (-not (git config --get credential.helper)) {
    git config --global credential.helper manager
}

Write-Host "Checking access to $RepoLabel (a sign-in window may open - complete it)..."
$env:GIT_TERMINAL_PROMPT = "1"
git ls-remote --heads $RemoteUrl *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Couldn't reach the repo yet - trying the sign-in once more..."
    git ls-remote --heads $RemoteUrl *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-Script "Can't access $RemoteUrl. Either the URL is wrong, the sign-in wasn't completed, or this account doesn't have access (the repo owner can add you as a collaborator). If the saved repo is wrong, delete $configName and run this again."
    }
}
Write-Host "Access OK."

# Pick the branch: saved/adopted value, else the remote's default branch.
if (-not $Branch) {
    $symref = (git ls-remote --symref $RemoteUrl HEAD 2>$null) -join "`n"
    $m = [regex]::Match($symref, 'ref:\s+refs/heads/(\S+)\s+HEAD')
    if ($m.Success) { $Branch = $m.Groups[1].Value } else { $Branch = "main" }
}
Write-Host "Publishing to $RepoLabel (branch: $Branch)"

# Remember the choice for next time.
@{ remoteUrl = $RemoteUrl; branch = $Branch } | ConvertTo-Json | Set-Content -Path $configPath

# Does that branch exist on the remote yet? (A brand-new empty repo won't have one.)
$remoteHasBranch = [bool](git ls-remote --heads $RemoteUrl $Branch 2>$null)

# ----------------------------------------------------------
# Step 4b: point downloader.ps1 at this same repo
#
# The downloader is a standalone file with the repo written inside it
# (it has to be - on a fresh machine there's nothing else to read the
# repo from yet). So every time this script runs, it rewrites the
# $repoUser / $repoName / $branch lines in any downloader.ps1 it finds
# (project root, tools/, or next to this script). The copy you hand out
# is then always aimed at the repo you just published to.
# ----------------------------------------------------------
if ($RemoteUrl -match 'github\.com[:/]+([^/]+)/([^/]+?)(\.git)?/?$') {
    $dlUser = $Matches[1]
    $dlName = $Matches[2]

    $downloaderPaths = @(
        (Join-Path $root "downloader.ps1"),
        (Join-Path $root "tools\downloader.ps1"),
        (Join-Path $PSScriptRoot "downloader.ps1")
    ) | Where-Object { Test-Path $_ } | ForEach-Object { (Resolve-Path $_).Path } | Select-Object -Unique

    foreach ($dl in $downloaderPaths) {
        $text = [IO.File]::ReadAllText($dl)

        if ($text -notmatch '(?m)^\s*\$repoUser\s*=') {
            Write-Host "Couldn't find the repo settings in $dl - leaving it alone."
            continue
        }

        $new = $text
        $new = [regex]::Replace($new, '(?m)^(\s*\$repoUser\s*=\s*)"[^"]*"', ('${1}"' + $dlUser + '"'))
        $new = [regex]::Replace($new, '(?m)^(\s*\$repoName\s*=\s*)"[^"]*"', ('${1}"' + $dlName + '"'))
        $new = [regex]::Replace($new, '(?m)^(\s*\$branch\s*=\s*)"[^"]*"', ('${1}"' + $Branch + '"'))

        if ($new -ne $text) {
            [IO.File]::WriteAllText($dl, $new, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "Updated $dl -> $dlUser/$dlName (branch: $Branch)"
        } else {
            Write-Host "Downloader already points at $dlUser/$dlName (branch: $Branch)."
        }
    }
    if (-not $downloaderPaths) {
        Write-Host "No downloader.ps1 found next to the project - skipping downloader update."
    }
} else {
    Write-Host "Repo isn't on github.com, so the downloader (which uses raw.githubusercontent.com) can't be pointed at it - skipping."
}

# ----------------------------------------------------------
# Step 5: attach this folder to the repo (or switch repos)
# ----------------------------------------------------------
if (Test-Path ".git") {
    $currentOrigin = git remote get-url origin 2>$null
    if (($LASTEXITCODE -eq 0) -and $currentOrigin -and ((Get-NormalizedUrl $currentOrigin) -ne (Get-NormalizedUrl $RemoteUrl))) {
        Write-Host ""
        Write-Host "This folder's git history is linked to a DIFFERENT repo:"
        Write-Host "  current: $currentOrigin"
        Write-Host "  new:     $RemoteUrl"
        $ans = Read-Host "Switch this folder to the new repo? Your files are untouched and the old .git folder is kept as a backup (y/n)"
        if ($ans -match '^[Yy]') {
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            Rename-Item ".git" ".git_backup_$stamp"
            Write-Host "Old git data saved as .git_backup_$stamp"
        } else {
            Stop-Script "Cancelled - nothing was changed."
        }
    }
}

if (-not (Test-Path ".git")) {
    Write-Host "Attaching this folder to $RemoteUrl (branch: $Branch)..."
    try {
        git init -q
        if ($LASTEXITCODE -ne 0) { throw "git init failed" }

        git symbolic-ref HEAD "refs/heads/$Branch"

        git remote add origin $RemoteUrl
        if ($LASTEXITCODE -ne 0) { throw "git remote add failed" }

        if ($remoteHasBranch) {
            git fetch origin $Branch -q
            if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }

            # reset --mixed moves HEAD/index to the fetched commit but
            # never touches your files on disk.
            git reset --mixed FETCH_HEAD -q
            if ($LASTEXITCODE -ne 0) { throw "git reset failed" }

            git branch --set-upstream-to=origin/$Branch $Branch 2>$null
        } else {
            Write-Host "The remote has no '$Branch' branch yet (new/empty repo) - the first push will create it."
        }
        Write-Host "Attached."
    } catch {
        Stop-Script "Couldn't attach this folder to the repo: $_"
    }
} else {
    $existingRemote = git remote 2>$null
    if ($existingRemote -notcontains "origin") {
        git remote add origin $RemoteUrl
    }
}

# ----------------------------------------------------------
# Step 6: pull, then build latest/
# ----------------------------------------------------------
# Pull first so you don't overwrite a teammate's newer push.
# --autostash keeps your uncommitted local edits safe during the pull.
if ($remoteHasBranch) {
    git pull --rebase --autostash -q origin $Branch
    if ($LASTEXITCODE -ne 0) {
        Stop-Script "git pull failed - there may be a conflict with a teammate's changes. Run 'git status' in $root to see what needs resolving."
    }
}

$newVersion = Get-Date -Format "yyyy-MM-dd-HHmm"

# Wipe and rebuild the published folder so deleted/renamed files don't
# linger in latest/ forever.
if (Test-Path $latestFolder) {
    Remove-Item $latestFolder -Recurse -Force
}
New-Item -ItemType Directory -Path $latestFolder | Out-Null

$manifest = @()

Get-ChildItem -Recurse -File | ForEach-Object {
    $relPath = $_.FullName.Substring((Get-Location).Path.Length + 1)
    $topDir  = $relPath.Split([IO.Path]::DirectorySeparatorChar)[0]

    if ($excludeDirs -contains $topDir) { return }
    if ($topDir -like ".git*") { return }          # .git, .gitignore folders, .git_backup_*
    if ($excludeFiles -contains $_.Name) { return }

    $dest = Join-Path $latestFolder $relPath
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item $_.FullName $dest -Force

    # manifest paths use forward slashes (they get joined onto a
    # raw.githubusercontent.com URL by the in-app updater)
    $manifest += ($relPath -replace '\\', '/')
}

$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $latestFolder "manifest.json")
Set-Content -Path (Join-Path $latestFolder "version.txt") -Value $newVersion

# ----------------------------------------------------------
# Step 7: commit + push
# ----------------------------------------------------------
git add $latestFolder

# Only look at latest/ - other unrelated local edits shouldn't count.
$hasChanges = git status --porcelain -- $latestFolder
if ($hasChanges) {
    git commit -m "Update to version $newVersion" -q
    if ($LASTEXITCODE -ne 0) {
        Stop-Script "git commit failed - nothing was published."
    }
} else {
    Write-Host "Nothing changed since the last publish - skipping commit, still trying push in case an earlier push failed."
}

git push -u origin $Branch
if ($LASTEXITCODE -ne 0) {
    Stop-Script "git push FAILED - nothing was published. You're signed in, but this account probably doesn't have write access to $RepoLabel (ask the repo owner to add you as a collaborator), or someone pushed in the meantime - just run this again."
}

Write-Host ""
Write-Host "Pushed version $newVersion to $RepoLabel, branch $Branch ($($manifest.Count) files)." -ForegroundColor Green
Write-Host "Reminder: your app's updater must point at this same repo/branch to find these files."
pause
