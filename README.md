# CosmoWatch

One-click replay watching for Cosmonarchy. Click a game on the Matches site →
the game opens with that replay playing. Nobody ever has to know which version
of the game a replay needs.

```
cosmonarchy://watch?match=7c482cba-83fe-514d-a019-3f39e1e8f3f2&file=6ada91dee3ec4a129c7977e5
        │                                                      │
        └─ browser calls this on "Watch"            replay file id (optional - falls back
                                                        to the match's main replay)
```

## What happens on a click

1. **Resolve** — CosmoWatch asks the ReplayKraken API (`cosmonarchy.com/api/matches/<uuid>`)
   which game version the replay needs. Replays report a short git SHA + build
   kind (`Release` / `Prerelease`), and the API expands it to the full commit.
2. **Ensure version** — the game folder is used as a *partial git working tree*.
   If the exact version isn't checked out, git fetches and switches to it.
3. **Download replay** — saved to `Maps\Replays\` inside the game folder
   (the standard StarCraft 1.16.1 replay location).
4. **Launch** — `Cosmonarchy BW.exe` is started with the replay path, straight
   into playback.

## How space is saved

This is the whole point of the design, and every piece of it was verified
against the live infrastructure:

| Mechanic | Effect |
|---|---|
| Versions are **git commits** of the public build repos | one store serves every version |
| **Partial clone** (`--filter=blob:none`) | the *entire* version history costs **~2.4 MB** of metadata |
| **Lazy blob fetch** | file contents download only when a version is actually watched (~2 GB once per fresh version) |
| **Content addressing** | files unchanged between versions are shared by hash — weekly patches cost only their actual diffs |
| **One working tree = the game folder** | zero copies, zero junctions, zero duplication |
| `cleanup` | compacts the store and prunes old replay files |

Compare with the alternative (a full 2 GB download per version, cached as
separate folders): a user who watches replays across 10 different versions
keeps ~2 GB instead of ~20 GB.

## Requirements

- Windows 10/11, an existing Cosmonarchy install (installed via Fraud Launcher 2).
- **Git for Windows** (`winget install Git.Git`) — used as the version store.
- PowerShell 5.1 (built into Windows).

## Install

```bat
:: from the CosmoWatch folder:
CosmoWatch.cmd install
:: or point it at the game folder explicitly:
CosmoWatch.cmd install -GameDir C:\Users\You\Games\CosmonarchyStarcraft
```

This registers the `cosmonarchy://` URL protocol in the current user's registry
(no admin rights needed) and saves the game-folder location.

Optional: `CosmoWatch.cmd install -AssociateRep` also makes double-clicked
`.rep` files route through CosmoWatch. It checks the file's magic bytes first,
so vanilla StarCraft replays are never hijacked.

## Usage

```bat
CosmoWatch.cmd watch <cosmonarchy:// link or match UUID>   :: the deep-link flow
CosmoWatch.cmd watch <uuid> -NoLaunch                      :: prepare version + replay without starting the game
CosmoWatch.cmd replay "C:\...\slav-2cc5a23-7c482cba.rep"  :: open a downloaded replay
CosmoWatch.cmd versions                                    :: current version + history
CosmoWatch.cmd cleanup                                     :: compact store, prune old replays
CosmoWatch.cmd uninstall                                   :: remove handlers
```

Offline behaviour: if the API is unreachable but the replay was watched before,
the required version is restored from local history.

## Site integration

See [`site-integration.md`](site-integration.md) for the "Watch" button snippet
for cosmonarchy.com/matches (including a fallback when no handler is installed).

## Notes & caveats

- The first watch after a fresh install downloads the target version's files
  (~2 GB). Subsequent versions only download what changed.
- Launch mechanism (verified against the shipped binaries): `Cosmonarchy BW.exe`
  is a plugin-loader stub — it patches `Starcraft.exe` in the same folder with
  the mod's plugins and forwards command-line arguments, so passing the replay
  path starts playback in the modded engine.
- CosmoWatch switches the checked-out version. Close the game before watching
  a replay that needs a different version (CosmoWatch refuses to run while
  another instance is switching).
- Don't move the CosmoWatch folder after `install` — or just re-run `install`.
- If the game folder already has a `.git` left by Fraud Launcher 2 (it uses
  git under the hood too), CosmoWatch reuses it instead of re-downloading.
- ReplayKraken is a beta service; if it's down, only previously-watched
  replays can be opened offline.
