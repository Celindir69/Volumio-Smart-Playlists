# Artwork One on a Musical Fidelity MX-Stream (experimental, untested)

[Artwork One](https://github.com/michaltamas/volumio-artwork-one) is written for Volumio 4.x and is
installed there as an alternative web interface. The MX-Stream's factory firmware (Volumio 2 OEM,
Node v8.11.1) has no way to select a third-party interface: nothing in `/volumio` reads
`/data/thirdPartyUisList.json` or `/data/active_volumio_ui`, and `/volumio/http/index.js` serves
`www` or `www3` from fixed paths. The official installer therefore does **not** apply.

This document describes a way to try the interface anyway, **without touching `/volumio`**: the
build is served by a tiny separate web server, and the page talks to the player's own backend on
port 3000. Nothing here has been tested on the device; it is a recipe to try, not a guarantee.

## What was checked on the device

- `curl -si -H "Origin: http://example.test" http://localhost:3000/api/v1/getState` answers with
  `Access-Control-Allow-Origin: *`, so the REST API accepts requests from another port.
- The player's interface is served by Node/Express on port 3000 (no nginx, nothing on port 80).
- `GET /api/v1/getState` returns the fields Artwork One reads (`status`, `title`, `albumart`,
  `samplerate`, `bitdepth`, ...).

## What is unknown

- Whether Socket.IO 1.x on this build accepts a connection from another port (it normally does).
- Whether every screen works against this older backend (Zones, outputs, plugin pages, settings).
- The Companion plugin is **not** installed: theme and pins stay per browser.

## Steps

### 1. Build on a normal computer (Node 20.19 or newer, or Node 22)

Do not build on a Volumio player: its Node is too old (this build needs Node `^20.19.0 || >=22.12.0`,
Vite 8) and `npm ci` needs several hundred MB, which a player's small system partition does not
have (`ENOSPC: no space left on device`). The address of the MX-Stream, with port 3000, is baked in
at build time:

```bash
git clone https://github.com/michaltamas/volumio-artwork-one.git
cd volumio-artwork-one
npm ci
VITE_VOLUMIO_HOST=http://mxstream.local:3000 npm run build
```

Use the player's IP address instead of `mxstream.local` if the name does not resolve everywhere.
The result is the `dist/` folder.

Without a suitable Node on the computer, Docker works too (run it inside the cloned folder):

```bash
docker run --rm -v "$PWD":/app -w /app -e VITE_VOLUMIO_HOST=http://mxstream.local:3000 \
  node:22 sh -c "npm ci && npm run build"
```

The release archive of Artwork One cannot be used for this: it is built without a player address
and would talk to the server on port 8080 instead of the player.

### 2. Copy the build to the player

Copy the **contents** of `dist/` to `/mnt/INTERNAL/artwork-one/` (over the Samba share, or `scp`),
so that `/mnt/INTERNAL/artwork-one/index.html` exists. Copy `scripts/artwork-one-static-server.js`
from this repository next to it.

### 3. Start the server as the `volumio` user

Everything on this device should run as `volumio`, not `volumiooem` (see
[`smart-playlist-plugin`'s Volumio 2 notes](https://github.com/Celindir69/smart-playlist-plugin/blob/main/docs/volumio2-mxstream-install.md)):

```bash
su volumio
node /mnt/INTERNAL/artwork-one/artwork-one-static-server.js /mnt/INTERNAL/artwork-one 8080
```

It prints `serving ... on port 8080`. It is read-only (GET/HEAD), stays inside the folder, and
falls back to `index.html` for paths without a file extension, so reloading and deep links work.

### 4. Open it

`http://mxstream.local:8080` in a browser on the same network.

If you use the Volumio kiosk on the player's own display: the kiosk identifies itself as
`volumiokiosk` and always gets the classic interface of the player on port 3000. Point the
kiosk's start address at `http://localhost:8080` to show Artwork One instead; how the kiosk is
started depends on the device and was not looked at here.

## Rolling back

Nothing outside `/mnt/INTERNAL/artwork-one` is changed.

1. Stop the server with Ctrl-C.
2. Delete `/mnt/INTERNAL/artwork-one`.
3. If you changed the kiosk's start address, set it back.

## Making it permanent (optional, not tested)

Only once the test is convincing: start the server at boot with a systemd unit running as
`volumio` (`ExecStart=/usr/bin/node /mnt/INTERNAL/artwork-one/artwork-one-static-server.js /mnt/INTERNAL/artwork-one 8080`,
`Restart=on-failure`). Check the real path of `node` with `which node` first, and that
`/mnt/INTERNAL` is mounted before the unit starts.

## Measuring the load

Compare on the same device and the same track, with the stock interface and with Artwork One, in
the same browser: `top` (the browser, the Volumio backend, MPD), `vcgencmd measure_temp`,
`vcgencmd get_throttled`, `free -m`; at rest, during playback and on track changes.
