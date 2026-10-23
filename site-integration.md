# Site integration: "Watch" buttons on the Matches page

This is the tiny front-end piece for cosmonarchy.com/matches. Each match card
(or replay row) gets a **Watch** button that emits the deep link handled by
CosmoWatch.

## 1. The link

Build it from the data the ReplayKraken API already returns:

```js
const matchUuid = match.matchUuid;          // e.g. "7c482cba-83fe-514d-a019-3f39e1e8f3f2"
const fileId    = match.mainReplay.fileId;  // the canonical replay, or any replays[i].fileId

const watchUrl = `cosmonarchy://watch?match=${matchUuid}&file=${fileId}`;
```

Every match object already carries everything needed (gameVersion, kind, and
the download URLs), so no new API work is required for the button itself.

## 2. Click handling with fallback

The challenge: browsers give no direct "is this protocol handled?" answer.
Standard pattern — attempt the navigation, and if we're still running shortly
after, assume no handler is installed and show fallback help.

```js
function watchMatch(matchUuid, fileId) {
  const url = `cosmonarchy://watch?match=${matchUuid}&file=${fileId}`;
  const start = Date.now();

  // Attempt the deep link. If a handler exists, the browser switches away
  // and this page's timer effectively pauses / the page loses visibility.
  window.location.href = url;

  setTimeout(() => {
    if (Date.now() - start < 1500 && !document.hidden) {
      showWatchFallback(matchUuid, fileId);
    }
  }, 1200);
}

function showWatchFallback(matchUuid, fileId) {
  // No CosmoWatch installed. Offer the manual path:
  // 1. Copy the command line below.
  // 2. Download the replay file (the existing download button).
  const cmd = `cosmowatch watch ${matchUuid}${fileId ? " -File " + fileId : ""}`;
  // Render: "Install CosmoWatch" link (to the tool's install page) +
  // a "copy command" box containing `cmd`.
}
```

Notes:

- `document.hidden` checks whether the deep link actually navigated away
  (a handled protocol does; an unhandled one doesn't).
- Also listen once for `visibilitychange` to dismiss the fallback quickly if
  the game opened after all.
- Keep the existing per-replay **Download** button — it remains the fallback
  path for users without CosmoWatch.

## 3. What CosmoWatch expects

- `match` — the 36-char match UUID (API field `matchUuid`).
- `file` — optional, the 24-char replay file id (API field `fileId`).
  Omitted → CosmoWatch uses `mainReplay`.

CosmoWatch resolves everything else (version, build kind, download URL) from
`GET /api/matches/<uuid>`, so the site stays dumb and the protocol stays stable
even as the API evolves.

## 4. Optional polish

- A "**▶ Watch**" primary button next to the existing download button, with
  the deep-link URL also available on right-click → copy link.
- On the match detail view: "Watch in game" + "Watch with commentary" links
  per replay variant (useful for the desync/randoms variants).
- An install banner (shown once) pointing users at CosmoWatch, after their
  first deep link without a handler.
