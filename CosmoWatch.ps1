# CosmoWatch.ps1
# ---------------------------------------------------------------------------
# One-click replay watcher for Cosmonarchy.
#
# Deep link:   cosmonarchy://watch?match=<matchUuid>&file=<fileId>
# CLI:         powershell -ExecutionPolicy Bypass -File CosmoWatch.ps1 watch <url|uuid>
#
# What it does when you click a game:
#   1. Resolves the match via the ReplayKraken API (map, players, replay file,
#      required game version + build kind).
#   2. Makes sure the *exact* game version for that replay is installed, using
#      the game folder itself as a lazy (partial) git working tree:
#        - the whole version history costs ~2-3 MB of metadata
#        - file contents download only for versions you actually watch
#        - unchanged files across versions are shared by content hash (0 extra disk)
#        - there is exactly ONE copy of the game files (the game dir itself)
#   3. Downloads the replay into the game's Maps\Replays folder.
#   4. Launches the game straight into the replay. The user never sees or
#      picks a version.
#
# Verified against the live ReplayKraken API and the live GitLab repos.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "watch",

    [Parameter(Position=1)]
    [string]$Target = "",

    [switch]$NoLaunch,
    [switch]$AssociateRep,
    [string]$GameDir = "",
    [string]$Log = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
Set-Variable -Name REPO_BASE -Value "https://gitlab.com/the-no-frauds-club" -Option Constant
Set-Variable -Name REMOTE_RELEASE -Value "https://gitlab.com/the-no-frauds-club/cosmonarchy-bw-release.git" -Option Constant
Set-Variable -Name REMOTE_PRERELEASE -Value "https://gitlab.com/the-no-frauds-club/cosmonarchy-bw-prerelease.git" -Option Constant
Set-Variable -Name API_BASE -Value "https://cosmonarchy.com/api" -Option Constant
Set-Variable -Name GAME_EXE -Value "Cosmonarchy BW.exe" -Option Constant
Set-Variable -Name REP_MAGIC -Value ([byte[]](0xA7,0x7E,0x7E,0x2B)) -Option Constant
Set-Variable -Name MAX_RECENT -Value 20 -Option Constant

$ConfigDir  = Join-Path $env:LOCALAPPDATA "CosmoWatch"
$ConfigFile = Join-Path $ConfigDir "config.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg) { Write-Host "  $msg" }
function Write-Err([string]$msg)  { Write-Host "ERROR: $msg" -ForegroundColor Red }

function Read-Config {
    if (Test-Path $ConfigFile) {
        try { return (Get-Content $ConfigFile -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Write-Config($cfg) {
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content $ConfigFile -Encoding UTF8
}

# Locate the game folder ("Cosmonarchy BW.exe" at its root).
function Find-GameDir {
    if ($GameDir -and (Test-Path (Join-Path $GameDir $GAME_EXE))) { return (Resolve-Path $GameDir).Path }

    $cfg = Read-Config
    if ($cfg -and $cfg.gameDir -and (Test-Path (Join-Path $cfg.gameDir $GAME_EXE))) { return $cfg.gameDir }

    # 1) Exact candidate paths (fast; covers the launcher's defaults).
    $bases = @($env:USERPROFILE) + @((Get-PSDrive -PSProvider FileSystem).Root | ForEach-Object { $_.TrimEnd('\') })
    $candidates = foreach ($d in $bases) {
        Join-Path $d "CosmonarchyStarcraft"
        (Join-Path $d "Games\CosmonarchyStarcraft")
        (Join-Path $d "Starcraft\CosmonarchyStarcraft")
        (Join-Path $d "Documents\CosmonarchyStarcraft")
    }
    foreach ($c in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path (Join-Path $c $GAME_EXE)) { return (Resolve-Path $c).Path }
    }

    # 2) Shallow name-based scan of likely roots (bounded, so it stays fast).
    $roots = @($env:USERPROFILE, (Join-Path $env:USERPROFILE "Games"),
               (Join-Path $env:USERPROFILE "Documents"), (Join-Path $env:PUBLIC "Games"))
    foreach ($d in (Get-PSDrive -PSProvider FileSystem).Root) {
        $g = Join-Path $d.TrimEnd('\') "Games"
        if (Test-Path $g) { $roots += $g }
    }
    foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            $found = Get-ChildItem -Path $root -Directory -Filter "Cosmonarchy*" -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                     Where-Object { Test-Path (Join-Path $_.FullName $GAME_EXE) } | Select-Object -First 1
            if ($found) { return $found.FullName }
        } catch { }
    }
    return $null
}

function Get-GitExe {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) { return $git.Source }
    # Common portable install locations
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
                     "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Invoke-Git([string]$git, [string]$gameDir, [string[]]$args) {
    & $git -C $gameDir @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args[0]) failed (exit $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
# ReplayKraken API
# ---------------------------------------------------------------------------
function Get-Match([string]$matchUuid) {
    Write-Step "Resolving match $matchUuid ..."
    try {
        return Invoke-RestMethod -Uri "$API_BASE/matches/$matchUuid" -TimeoutSec 30
    } catch {
        return $null
    }
}

# gameVersion on ReplayKraken is a short (7-hex) git SHA; expand it to the full
# SHA via the GitLab API so git can fetch it precisely.
function Get-FullSha([string]$kind, [string]$shortSha) {
    $repo = if ($kind -eq "Prerelease") { "cosmonarchy-bw-prerelease" } else { "cosmonarchy-bw-release" }
    try {
        $c = Invoke-RestMethod -Uri "$REPO_BASE/api/v4/projects/the-no-frauds-club%2F$repo/repository/commits/$shortSha" -TimeoutSec 30
        if ($c.id) { return $c.id }
    } catch { }
    return $null
}

function Get-RemoteUrl([string]$kind) {
    if ($kind -eq "Prerelease") { return $REMOTE_PRERELEASE }
    return $REMOTE_RELEASE
}

# ---------------------------------------------------------------------------
# Version management (the space-optimal part)
# ---------------------------------------------------------------------------
function Initialize-GameRepo([string]$git, [string]$gameDir, [string]$kind) {
    if (Test-Path (Join-Path $gameDir ".git")) {
        Write-Info "Game folder is already a git repository - reusing it."
        return
    }
    $hasFiles = (Test-Path $gameDir) -and (@(Get-ChildItem $gameDir -Force -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $hasFiles) {
        # Empty/new folder: a real partial clone gives lazy file fetching out
        # of the box, plus the full version history for ~2-3 MB of metadata.
        Write-Step "Creating version store (partial clone: ~2-3 MB metadata, game files stream in on demand) ..."
        $url = Get-RemoteUrl $kind
        Invoke-Git $git (Split-Path $gameDir -Parent) @("clone", "--filter=blob:none", "--no-checkout", $url, $gameDir)
        Invoke-Git $git $gameDir @("remote", "add", "release", $REMOTE_RELEASE)
        Invoke-Git $git $gameDir @("remote", "add", "prerelease", $REMOTE_PRERELEASE)
    } else {
        # Existing launcher install without .git: init in place; lazy fetching
        # is switched on before the first fetch (see Switch-Version).
        Write-Step "Initializing version store in existing game folder ..."
        Invoke-Git $git $gameDir @("init", "-q")
        Invoke-Git $git $gameDir @("remote", "add", "release", $REMOTE_RELEASE)
        Invoke-Git $git $gameDir @("remote", "add", "prerelease", $REMOTE_PRERELEASE)
    }
    # Keep the mod's own transient files out of git's way. .git/info/exclude is
    # local-only, so a version switch (git reset --hard) never touches it.
    $exclude = Join-Path $gameDir ".git\info\exclude"
    $lines = @("", "# CosmoWatch additions", "cosmonarchy.yml", "ddraw.ini", "*.err", "Maps/Replays/")
    Add-Content -Path $exclude -Value $lines -Encoding ASCII
}

function Ensure-Remote([string]$git, [string]$gameDir, [string]$kind) {
    $name = if ($kind -eq "Prerelease") { "prerelease" } else { "release" }
    $url  = Get-RemoteUrl $kind
    $remotes = & $git -C $gameDir remote -v 2>&1
    if ($remotes -match "^$name\s") {
        # Update the URL in case the repo moved.
        & $git -C $gameDir remote set-url $name $url 2>&1 | Out-Null
    } else {
        Invoke-Git $git $gameDir @("remote", "add", $name, $url)
    }
}

function Switch-Version([string]$git, [string]$gameDir, [string]$kind, [string]$fullSha) {
    Ensure-Remote $git $gameDir $kind
    $remote = if ($kind -eq "Prerelease") { "prerelease" } else { "release" }

    # Switch on lazy file fetching for this repo (git needs this before the
    # --filter flag actually spares the blobs; setting it twice is harmless).
    & $git -C $gameDir config extensions.partialClone $remote 2>&1 | Out-Null

    # Already on it?
    $cur = (& $git -C $gameDir rev-parse HEAD 2>$null)
    if ($cur -and ($cur.Trim() -eq $fullSha)) {
        Write-Info "Game is already on the required version."
        return
    }

    Write-Step "Fetching version $($fullSha.Substring(0,7)) ($kind) - only downloads what's missing ..."
    Invoke-Git $git $gameDir @("fetch", "--progress", "--filter=blob:none", $remote, $fullSha)

    Write-Step "Switching game to that version (missing files stream in on demand) ..."
    # reset --hard is safe here: untracked local files (StarCraft 1.16.1 base
    # data, cosmonarchy.yml, ddraw.ini, replays) are left untouched; only
    # repo-tracked game files are set to the target version. Not quiet, so the
    # user sees git's "Updating files" progress while blobs stream in.
    Invoke-Git $git $gameDir @("reset", "--hard", $fullSha)
    Write-Info "Game is now on $($fullSha.Substring(0,7))."
}

# ---------------------------------------------------------------------------
# Replay download
# ---------------------------------------------------------------------------
function Save-Replay([string]$matchUuid, [string]$fileId, [string]$gameDir, $replay) {
    $replaysDir = Join-Path $gameDir "Maps\Replays"
    if (-not (Test-Path $replaysDir)) { New-Item -ItemType Directory -Path $replaysDir -Force | Out-Null }

    # Prefer the server-provided filename (e.g. "slav-2cc5a23-7c482cba-83fe-.rep").
    $name = ""
    if ($replay.replayInfo.uploaderName) {
        $name = "$($replay.replayInfo.uploaderName)-$($replay.gameVersion)-$($matchUuid.Substring(0,8)).rep"
    } else {
        $name = "$matchUuid-$fileId.rep"
    }
    $name = ($name -replace '[<>:"/\\|?*]', '_')
    $dest = Join-Path $replaysDir $name

    $url = "$API_BASE/matches/$matchUuid/download/$fileId"
    if (Test-Path $dest) {
        # Cheap size check; re-download if the file looks truncated.
        $expected = 0
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 30
            $expected = [long]$resp.Headers["Content-Length"]
        } catch { $expected = 0 }
        $size = (Get-Item $dest).Length
        if ($expected -eq 0 -or $size -eq $expected) {
            Write-Info "Replay already cached: $name"
            return $dest
        }
    }

    Write-Step "Downloading replay: $name ..."
    Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 300 | Out-Null
    Write-Info ("Replay saved ({0:N1} KB)." -f ((Get-Item $dest).Length / 1KB))
    return $dest
}

# ---------------------------------------------------------------------------
# Recent list (offline fallback + the .rep double-click path)
# ---------------------------------------------------------------------------
function Update-Recent($cfg, $entry) {
    if (-not $cfg) { $cfg = [pscustomobject]@{ gameDir=""; keepReplays="recent"; recent=@() } }
    if (-not $cfg.recent) { $cfg | Add-Member -NotePropertyName recent -NotePropertyValue @() -Force }
    $recent = @($cfg.recent | Where-Object { $_.matchUuid -ne $entry.matchUuid -or $_.fileId -ne $entry.fileId })
    $recent = @($entry) + $recent
    if ($recent.Count -gt $MAX_RECENT) { $recent = @($recent | Select-Object -First $MAX_RECENT) }
    $cfg.recent = $recent
    $cfg.gameDir = $entry.gameDir
    Write-Config $cfg
}

function Find-Recent($cfg, [string]$matchUuid, [string]$fileId) {
    if (-not $cfg -or -not $cfg.recent) { return $null }
    foreach ($r in $cfg.recent) {
        if ($r.matchUuid -eq $matchUuid -and (-not $fileId -or $r.fileId -eq $fileId)) { return $r }
        if (-not $fileId -and $r.matchUuid -eq $matchUuid) { return $r }
    }
    return $null
}

# ---------------------------------------------------------------------------
# The core flow
# ---------------------------------------------------------------------------
function Parse-DeepLink([string]$s) {
    $s = $s.Trim()
    if ($s -notmatch '^cosmonarchy://') { return $null }
    $rest = $s.Substring("cosmonarchy://".Length)
    $r = [pscustomobject]@{ matchUuid=""; fileId="" }

    if ($rest -match '^watch/([0-9a-fA-F-]{36})(?:/([0-9a-fA-F]{20,}))?') {
        $r.matchUuid = $Matches[1]
        if ($Matches[2]) { $r.fileId = $Matches[2] }
        return $r
    }
    if ($rest -match '^watch\?(.+)$') {
        $q = $Matches[1]
        if ($q -match '(?:^|&)match=([0-9a-fA-F-]{36})(?:&|$)') { $r.matchUuid = $Matches[1] }
        if ($q -match '(?:^|&)file=([0-9a-fA-F]{20,})(?:&|$)') { $r.fileId = $Matches[1] }
        if ($r.matchUuid) { return $r }
    }
    return $null
}

function Invoke-Watch([string]$target) {
    $link = Parse-DeepLink $target
    $matchUuid = ""
    $fileId = ""
    if ($link) { $matchUuid = $link.matchUuid; $fileId = $link.fileId }
    elseif ($target -match '^[0-9a-fA-F-]{36}$') { $matchUuid = $target }
    else {
        Write-Err "Unrecognised target. Use a cosmonarchy:// link or a match UUID."
        return
    }

    $cfg = Read-Config
    $gameDir = Find-GameDir
    if (-not $gameDir) {
        Write-Err "Cosmonarchy game folder not found. Point me at it:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File CosmoWatch.ps1 install -GameDir C:\path\to\CosmonarchyStarcraft"
        return
    }

    # --- Resolve the replay (API first, local cache as offline fallback) ---
    $match = Get-Match $matchUuid
    $replay = $null
    if ($match) {
        if (-not $match.replays -or @($match.replays).Count -eq 0) {
            Write-Err "This match has no replays available."
            return
        }
        if ($fileId) {
            $replay = @($match.replays | Where-Object { $_.fileId -eq $fileId } | Select-Object -First 1)
            if (-not $replay) { Write-Err "Replay file $fileId not found in this match."; return }
        } else {
            if ($match.mainReplay) { $replay = $match.mainReplay }
            else { $replay = @($match.replays)[0] }
        }
    } else {
        Write-Info "ReplayKraken API unreachable - trying local history ..."
        $cached = Find-Recent $cfg $matchUuid $fileId
        if (-not $cached) {
            Write-Err "Can't resolve this replay (API unreachable and it's not in local history)."
            return
        }
        Write-Info "Using cached version info from a previous watch."
        $replay = [pscustomobject]@{
            matchUuid = $cached.matchUuid
            fileId = $cached.fileId
            gameVersion = $cached.gameVersion
            gameVersionKind = $cached.kind
            replayInfo = [pscustomobject]@{ mapName = $cached.map; uploaderName = $cached.uploader }
        }
    }

    # gameVersionKind sits at the match level in the ReplayKraken API; the
    # per-replay object carries gameVersion. Fall back across both just in
    # case the API shape evolves.
    $kind = if ($match -and $match.gameVersionKind) { $match.gameVersionKind } else { $replay.gameVersionKind }
    if ($kind -ne "Release" -and $kind -ne "Prerelease") {
        Write-Err "Unknown game build kind '$kind'."
        return
    }
    $shortSha = if ($replay.gameVersion) { $replay.gameVersion } else { $match.gameVersion }
    if (-not $shortSha -or $shortSha -notmatch '^[0-9a-fA-F]{7,40}$') {
        Write-Err "Replay does not report a valid game version."
        return
    }

    # Pretty summary of what we're about to watch.
    $map = ""
    if ($replay.replayInfo) { $map = $replay.replayInfo.mapName }
    $players = ""
    if ($replay.replayInfo -and $replay.replayInfo.teams) {
        $players = @($replay.replayInfo.teams | Where-Object { $_ -and $_.players } |
            ForEach-Object { $_.players } | ForEach-Object { $_.name }) -join " vs "
    }
    Write-Host ""
    Write-Host "CosmoWatch" -ForegroundColor Magenta
    if ($map)    { Write-Info "Map:     $map" }
    if ($players){ Write-Info "Players: $players" }
    Write-Info "Needs:   $kind build @ $($shortSha.Substring(0,7))"

    # --- Ensure tooling ---
    $git = Get-GitExe
    if (-not $git) {
        Write-Err "Git was not found. Install it once with:  winget install Git.Git"
        Write-Err "(or install Git for Windows and make sure 'git' is on your PATH)."
        return
    }

    # Serialise version switches (two CosmoWatch runs at once would fight).
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
    $mutex = New-Object System.Threading.Mutex($false, "Global\CosmoWatchSwitch")
    try {
        if (-not $mutex.WaitOne(0)) {
            Write-Err "Another CosmoWatch instance is already switching versions. Wait for it to finish."
            $mutex.Dispose()
            return
        }
    } catch {
        Write-Err "Could not take the version-switch lock (another instance may be running)."
        return
    }
    try {
        # --- Ensure the exact version ---
        Initialize-GameRepo $git $gameDir $kind
        $fullSha = Get-FullSha $kind $shortSha
        if (-not $fullSha) {
            Write-Info "GitLab lookup failed - asking git directly ..."
            $fullSha = $shortSha  # git fetch may still accept a unique short SHA
        }
        Switch-Version $git $gameDir $kind $fullSha

        # --- Download the replay ---
        $replayPath = Save-Replay $matchUuid $replay.fileId $gameDir $replay

        # --- Remember for offline re-watch ---
        Update-Recent $cfg ([pscustomobject]@{
            matchUuid = $matchUuid
            fileId = $replay.fileId
            gameVersion = $shortSha
            kind = $kind
            map = $map
            uploader = if ($replay.replayInfo) { $replay.replayInfo.uploaderName } else { "" }
            players = $players
            file = $replayPath
            gameDir = $gameDir
            date = (Get-Date).ToString("s")
        })

        if ($NoLaunch) {
            Write-Info "Version ready. Replay downloaded to:"
            Write-Info "  $replayPath"
            return
        }

        # --- Launch straight into the replay ---
        Write-Step "Launching the game with the replay ..."
        $exe = Join-Path $gameDir $GAME_EXE
        Start-Process -FilePath $exe -ArgumentList ('"{0}"' -f $replayPath) -WorkingDirectory $gameDir
        Write-Info "Have fun!"
    } finally {
        [void]$mutex.ReleaseMutex(); $mutex.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Install / uninstall handlers
# ---------------------------------------------------------------------------
function Install-Handlers {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $scriptPath = Join-Path $scriptDir "CosmoWatch.ps1"
    if (-not (Test-Path $scriptPath)) {
        Write-Err "Could not locate CosmoWatch.ps1 (looked in $scriptDir). Run install from the tool's folder."
        return
    }
    $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    # Custom URL protocol: cosmonarchy://watch?match=...&file=...
    $proto = "HKCU:\Software\Classes\cosmonarchy"
    New-Item -Path $proto -Force | Out-Null
    Set-ItemProperty -Path $proto -Name "(default)" -Value "URL:Cosmonarchy Replay Protocol"
    New-ItemProperty -Path $proto -Name "URL Protocol" -Value "" -Force | Out-Null
    $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" watch "%1"' -f $pwsh, $scriptPath
    New-Item -Path "$proto\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path "$proto\shell\open\command" -Name "(default)" -Value $cmd

    if ($AssociateRep) {
        # Optional: double-clicked .rep files route through CosmoWatch.
        # We verify the Cosmonarchy magic bytes at runtime so vanilla replays
        # are never mis-handled.
        New-Item -Path "HKCU:\Software\Classes\CosmoWatch.Replay\shell\open\command" -Force | Out-Null
        Set-ItemProperty -Path "HKCU:\Software\Classes\CosmoWatch.Replay\shell\open\command" -Name "(default)" `
            -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" replay "%1"' -f $pwsh, $scriptPath)
        New-Item -Path "HKCU:\Software\Classes\.rep" -Force | Out-Null
        Set-ItemProperty -Path "HKCU:\Software\Classes\.rep" -Name "(default)" -Value "CosmoWatch.Replay"
        Write-Info ".rep association installed (opt-in)."
    }

    # Persist the game dir if one was given / found.
    $cfg = Read-Config
    if (-not $cfg) { $cfg = [pscustomobject]@{ gameDir=""; keepReplays="recent"; recent=@() } }
    if ($GameDir) { $cfg.gameDir = (Resolve-Path $GameDir).Path }
    elseif (-not $cfg.gameDir) {
        $found = Find-GameDir
        if ($found) { $cfg.gameDir = $found; Write-Info "Detected game folder: $found" }
        else { Write-Info "Game folder not auto-detected. Re-run with -GameDir C:\path\to\CosmonarchyStarcraft once the game is installed." }
    }
    Write-Config $cfg

    Write-Host ""
    Write-Host "CosmoWatch installed." -ForegroundColor Green
    Write-Info "Deep links like  cosmonarchy://watch?match=<uuid>&file=<id>  now open replays directly."
    Write-Info "Tip: don't move this folder after install (or re-run install afterwards)."
}

function Uninstall-Handlers {
    Remove-Item "HKCU:\Software\Classes\cosmonarchy" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\Software\Classes\CosmoWatch.Replay" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\Software\Classes\.rep" -Force -ErrorAction SilentlyContinue
    Write-Info "Handlers removed."
}

# ---------------------------------------------------------------------------
# Replay-file entry point (double-clicked .rep)
# ---------------------------------------------------------------------------
function Invoke-ReplayFile([string]$path) {
    $path = (Resolve-Path $path).Path
    # Only handle Cosmonarchy's format (magic A7 7E 7E 2B). Vanilla replays
    # start with ASCII "StarCraft replay" and are not our business.
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $head = New-Object byte[] 4
        [void]$fs.Read($head, 0, 4)
    } finally { $fs.Close() }
    if ($head[0] -ne $REP_MAGIC[0] -or $head[1] -ne $REP_MAGIC[1] -or
        $head[2] -ne $REP_MAGIC[2] -or $head[3] -ne $REP_MAGIC[3]) {
        Write-Err "That is a vanilla StarCraft replay, not a Cosmonarchy replay. Open it with StarCraft: Remastered."
        return
    }

    # Find it in local history to learn its required version.
    $cfg = Read-Config
    $name = Split-Path $path -Leaf
    $entry = $null
    if ($cfg -and $cfg.recent) {
        $entry = @($cfg.recent | Where-Object { $_.file -eq $path } | Select-Object -First 1)
        if (-not $entry) {
            $entry = @($cfg.recent | Where-Object { (Split-Path $_.file -Leaf) -eq $name } | Select-Object -First 1)
        }
    }
    if (-not $entry) {
        Write-Err "I don't recognise this replay file. Open it from the Matches site instead - that always knows its version."
        return
    }
    Write-Info "Recognised: $($entry.map) - $($entry.players)"
    Invoke-Watch $entry.matchUuid
}

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------
function Show-Versions {
    $gameDir = Find-GameDir
    if (-not $gameDir) { Write-Err "Game folder not found."; return }
    $git = Get-GitExe
    if (-not $git) { Write-Err "git not found."; return }
    if (-not (Test-Path (Join-Path $gameDir ".git"))) {
        Write-Info "No version store in the game folder yet - it is created on first watch."
        return
    }
    $cur = (& $git -C $gameDir rev-parse HEAD 2>$null)
    $curSha = ""
    if ($cur) { $curSha = $cur.Trim() }
    Write-Info ("Current version: {0}" -f $(if ($curSha.Length -ge 7) { $curSha.Substring(0,7) } else { $curSha }))
    Write-Info "Remote history:"
    & $git -C $gameDir log --oneline -10 2>&1 | ForEach-Object { Write-Info "  $_" }
}

function Invoke-Cleanup {
    $gameDir = Find-GameDir
    if (-not $gameDir) { Write-Err "Game folder not found."; return }
    $git = Get-GitExe
    if (-not $git) { Write-Err "git not found."; return }
    if (Test-Path (Join-Path $gameDir ".git")) {
        Write-Step "Compacting version store ..."
        & $git -C $gameDir reflog expire --expire=now --all 2>&1 | Out-Null
        & $git -C $gameDir gc --prune=now 2>&1 | Out-Null
    }
    # Prune replays beyond the recent list.
    $cfg = Read-Config
    if ($cfg -and $cfg.recent) {
        $keep = @($cfg.recent | ForEach-Object { Split-Path $_.file -Leaf })
        $rd = Join-Path $gameDir "Maps\Replays"
        if (Test-Path $rd) {
            $removed = 0
            Get-ChildItem $rd -Filter *.rep | Where-Object { $keep -notcontains $_.Name } | ForEach-Object {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
            Write-Info "Removed $removed old replay file(s)."
        }
    }
    Write-Info "Cleanup complete."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
# Optional session transcript: -Log <path> on the command line, or "logFile" in
# config.json. Needed for the URL-protocol flow (the spawned console window
# isn't visible, but everything it prints lands in the log). Handy for
# debugging too.
$logPath = $Log
if (-not $logPath) {
    $preCfg = Read-Config
    if ($preCfg -and $preCfg.logFile) { $logPath = $preCfg.logFile }
}
if ($logPath) {
    try {
        $logDir = Split-Path $logPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Start-Transcript -Path $logPath -Append -Force | Out-Null
    } catch { }
}

try {
    switch ($Command.ToLowerInvariant()) {
        "watch"    { Invoke-Watch $Target }
        "replay"   { Invoke-ReplayFile $Target }
        "install"  { Install-Handlers }
        "uninstall"{ Uninstall-Handlers }
        "versions" { Show-Versions }
        "cleanup"  { Invoke-Cleanup }
        default {
            Write-Host "CosmoWatch - one-click Cosmonarchy replay watching"
            Write-Host ""
            Write-Host "  watch <cosmonarchy:// link | match UUID>   Open a game from the Matches site"
            Write-Host "  replay <path to .rep file>                Open a downloaded Cosmonarchy replay"
            Write-Host "  install [-GameDir <path>] [-AssociateRep]  Register the cosmonarchy:// handler"
            Write-Host "  uninstall                                  Remove the handler"
            Write-Host "  versions                                   Show current/latest versions"
            Write-Host "  cleanup                                    Compact version store, prune old replays"
        }
    }
} catch {
    Write-Err $_.Exception.Message
    if ($logPath) { try { Stop-Transcript | Out-Null } catch { } }
    exit 1
}
if ($logPath) { try { Stop-Transcript | Out-Null } catch { } }
