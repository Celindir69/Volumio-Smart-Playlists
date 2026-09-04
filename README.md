# Volumio Smart Playlists

A bash script for Volumio 3 that automatically builds native Volumio
playlists from a plain text file of rules - artist lists with optional
AND/OR filters on album, genre, year, originalyear, title, artist,
albumartist, comment, track number, duration, and days-since-added, plus
custom sort order, track limits, deduplication (e.g. when a best-of/live
compilation and the original studio album are both in your library), and
optional various-artists matching (for pulling an artist's appearances on
compilations into their own playlist).

Tested with a ~25,000 track FLAC/MP3/M4A/DSF/OGG library spread across
Internal Storage, a USB drive, and a NAS share on Volumio 3.

Also available as a Volumio plugin (settings page in the Volumio UI, no
SSH needed for day-to-day use) - see
[smart-playlist-plugin](https://github.com/Celindir69/smart-playlist-plugin),
which wraps this exact same script.

## What it does

- Reads a text file where each line describes one playlist you want built
  (artist name(s), optionally with filters).
- **Scans all of Volumio's standard music sources automatically** - Internal
  Storage, USB, and NAS - no path configuration needed. A source that isn't
  present on your system (e.g. no NAS connected) is silently skipped.
- Reads metadata (AlbumArtist, Artist, Title, Album, Genre, Year,
  OriginalYear, Comment, Track, Duration) directly from **Volumio's own
  MPD database** via `mpc` - the
  same index that powers Browse/Search, so there's no separate per-file
  scan to wait for at all (a ~24k track library that used to take ~20
  minutes on first run with a per-file tag scanner now takes a couple of
  seconds, every run). Requires a correctly installed Volumio with a
  reachable local MPD - see "How metadata is read" below.
- Supports `.flac`, `.mp3`, `.m4a`, `.dsf`, `.ogg`, `.opus`, `.aiff`/`.aif`,
  and `.ape` out of the box - configurable via the `AUDIO_EXTENSIONS` array
  in the script (see "Notes / limitations" below for why `.wav`/`.wma`
  aren't included by default).
- Writes native Volumio playlists (JSON files under `/data/playlist/`) so
  they show up directly in Volumio's own Playlist view - no manual import
  needed.
- Automatically removes playlists it previously created that are no longer
  present in your input file (orphan cleanup via a manifest file).

## Requirements

- Volumio 3, with a reachable local MPD (standard on any correctly
  installed Volumio)
- `jq` and `mpc`. `mpc` is part of Volumio's base image - nothing to
  install.
  ```bash
  sudo apt-get update
  sudo apt-get install -y jq
  ```

## Installation

1. Download `volumio-smart-playlists.sh` and copy it to your Volumio
   device, e.g. `/usr/local/bin/volumio-smart-playlists.sh`.
2. Make it executable:
   ```bash
   sudo chmod +x /usr/local/bin/volumio-smart-playlists.sh
   ```
3. That's it - no path configuration needed, it reads Internal Storage,
   USB, and NAS metadata straight from Volumio's own MPD (see "How
   metadata is read" below if your setup is non-standard).

## Where it stores its data

Rules, the metadata cache, the cleanup manifest, and the debug log all live
under `/data/smart_playlists_data/` by default - deliberately **not**
inside your music folder (so you won't accidentally edit/delete it while
browsing your music share). Override the location via the
`SMART_PLAYLISTS_WORK_DIR` environment variable if you'd rather keep it
elsewhere.

## How metadata is read

All metadata comes from Volumio's own MPD instance (`mpc search any ""`)
rather than from scanning files one by one - MPD already has the whole
library indexed for Browse/Search, so this is both far faster and one less
thing to keep in sync. This needs no configuration, and requires a
reachable local MPD; if `mpc` is missing or MPD doesn't respond, the script
exits with a clear error rather than guessing at an alternative (on a
correctly installed Volumio, MPD is always there).

What this means in practice:
- **AlbumArtist, Artist, Album, Title, Genre, Year, OriginalYear,
  Comment, Track, Duration**: come from MPD. No incremental cache is
  needed for these - a single MPD query is fast enough to just re-run in
  full on every invocation.
- **AlbumArtist and Artist are read as separate tags**, not merged - see
  "Compilations / Various Artists" below for why that matters.
- **`comment` needs an mpd.conf change.** MPD only exposes to `mpc` the
  tags listed in mpd.conf's `metadata_to_use` - by default this is
  "every known tag except `comment` and the `musicbrainz_*` ones", so
  `AlbumArtist`/`Artist`/`OriginalDate` are already available, but
  `Comment` is not until you add it explicitly:
  ```
  metadata_to_use    "artist,album,title,track,name,genre,date,composer,performer,disc,comment,albumartist,originaldate"
  ```
  (List every tag you actually want, not just `comment` - this setting
  *replaces* the default list rather than adding to it.) After editing
  `/etc/mpd.conf`, MPD's database must be **rebuilt, not just updated**,
  for the change to take effect (Volumio: Settings -> My Music -> use
  the "Rescan" / rebuild option, or `mpc rescan` followed by a restart of
  the `mpd` service). If you don't need `comment` filters, you can skip
  this entirely.
- **`added`** (days since added): MPD doesn't track "date added", so it
  still comes from the file's filesystem mtime via a plain `find` pass -
  just listing files and their timestamps, fast regardless of library
  size.
- **uri source mapping**: MPD reports each file's path relative to its own
  `music_directory` (default `/var/lib/mpd/music`), prefixed with the same
  source label Volumio itself uses for each of its standard music sources
  (Internal Storage, USB, NAS) - e.g. `INTERNAL/Artist/Album/Track.mp3`.
  That label is mapped to a playlist `uri` prefix via
  `SMART_PLAYLISTS_URI_PREFIXES` (newline-separated `label|uri_prefix`
  entries, default:
  ```
  INTERNAL|music-library/
  USB|music-library/
  NAS|mnt/
  ```
  ). **INTERNAL and USB are verified against a real device; NAS is
  UNVERIFIED** (no NAS source was available to test against) - if you use
  a NAS source, check the debug log for a "no configured uri prefix"
  warning and adjust `SMART_PLAYLISTS_URI_PREFIXES` if needed.

Relevant environment variables:
- `SMART_PLAYLISTS_MPD_MUSIC_DIR` - MPD's `music_directory` (default
  `/var/lib/mpd/music`; check `grep music_directory /etc/mpd.conf` if
  unsure).
- `SMART_PLAYLISTS_MPD_TIMEOUT` - seconds to wait for an MPD query before
  giving up (default `120`).
- `SMART_PLAYLISTS_URI_PREFIXES` - see above.

### Compilations / Various Artists

`AlbumArtist` and `Artist` are read as separate tags, which matters for
how the artist list (the part of a rule line before the first `|`)
decides what counts as a match:

- **Default** (`various=false`, or simply omitted): matches against
  `AlbumArtist`, falling back to `Artist` only when `AlbumArtist` is
  blank. This is unchanged from before and is what you want for a
  regular album, where every track's `AlbumArtist` is the artist itself.
  A compilation tagged `AlbumArtist=Various Artists` will **not** match
  here, even if an individual track's `Artist` is the artist you're
  looking for.
- **`various=true`** (must be its own `|` segment): matches against the
  raw `Artist` tag instead, so a track on a `Various Artists`
  compilation is picked up as long as its `Artist` tag names the right
  performer. Use this for a playlist that should also include an
  artist's guest spots/compilation appearances, not just their own
  albums.

This is exactly the tagging convention MusicBrainz Picard and MP3tag
both encourage for compilations: `AlbumArtist = Various Artists`,
`Artist = <the actual performer of that track>`. The `albumartist` and
`artist` filter fields (see below) expose the same two raw tags
independently for use in AND/OR filters, e.g. `albumartist=VariousArtists`
to build a "all my compilation tracks" playlist regardless of artist.

```
# Only Genesis' own albums
Genesis Albums::Genesis

# Genesis' own albums PLUS any compilation track where Genesis performed
Genesis Everywhere::Genesis|various=true
```

## Input file format

Create `smart_playlists.txt` inside `/data/smart_playlists_data/` (or
wherever `SMART_PLAYLISTS_WORK_DIR` points). One line per playlist:

```
[Playlist Name::]Artist1;Artist2;Artist3[|field<op>value[,field<op>value...]|...][|duplicate=true|false]
```

Whitespace around `::`, `;`, `|`, `,`, and operators (`=`, `~`, `>=`, etc.)
is ignored, so feel free to format for readability, e.g.:
```
Classic Rock 70s :: Genesis ; Supertramp ; Pink Floyd | album !~ Live | year >= 1973 | sort = year +
```
is exactly equivalent to the more compact
`Classic Rock 70s::Genesis;Supertramp;Pink Floyd|album!~Live|year>=1973|sort=year+`.

- Lines starting with `#` (optionally indented) are treated as comments and
  skipped.
- Blank lines are skipped.
- **Artist list**: any number of artist names separated by `;`, combined
  with OR (a track matches if its AlbumArtist matches *any* of them - or
  its Artist tag, if `various=true` is set; see "Compilations / Various
  Artists" above). Matching is case-insensitive and ignores
  spaces/dashes/underscores/dots.
- **`*` (wildcard artist)**: use `*` instead of an artist list to match
  tracks from **any** artist - useful for library-wide playlists that
  only filter on non-artist fields, e.g. `Recently Added::*|added<5`.
  The `*` must be followed by `|` (i.e. it needs to be its own segment,
  same as a real artist list would be) - a completely blank artist
  section without `*` and without a leading `|` right after `::` can't
  be reliably told apart from a filter and will be treated as an
  (unmatchable) artist name instead.
- **Playlist name** (optional): put a name followed by `::` before the
  artist list to control the exact filename/display name in Volumio.
  Without it, the name is derived automatically from the line.
- **Filters** (optional): any number of `|`-separated segments, combined
  with **AND**. Within a single segment, separate conditions with `,` to
  combine them with **OR**:
  ```
  |fieldA<op>valA,fieldB<op>valB|fieldC<op>valC
  ```
  means `(fieldA OR fieldB) AND fieldC` - i.e. conjunctive normal form
  (AND of ORs), which covers the vast majority of real-world queries
  without needing full parenthesized boolean expressions.
  - Fields: `album`, `genre`, `year`, `originalyear`, `title`, `artist`
    (raw Artist tag), `albumartist` (raw AlbumArtist tag), `comment`,
    `track`, `duration` (seconds), `added` (days since the file's mtime -
    see caveat below)
  - Operators: `=`, `!=`, `~` (contains), `!~` (does not contain), `>`,
    `>=`, `<`, `<=`
  - Numeric comparisons (`>`, `>=`, `<`, `<=`) apply to `year`,
    `originalyear`, `track`, `duration`, and `added`.
  - `originalyear` comes from MPD's `OriginalDate` tag (what Picard/MP3tag
    write for a reissue's *original* release date) - independent of
    `year`, which still reflects `Date` (the specific release/reissue
    you actually have). There's no fallback between the two: a track with
    no `OriginalDate` tag at all simply won't match any `originalyear`
    filter, so an `originalyear` filter only makes sense once you've
    actually tagged original release dates.
  - Note: if a value legitimately contains a comma, it will be
    mis-parsed as an OR split - this is a known limitation.
- **`duplicate=false`** (optional, special field, must be its own `|`
  segment): deduplicates the resulting playlist by normalized track title,
  keeping only the first match per title. Default is `true` (duplicates
  allowed, i.e. original behavior).
- **`various=true`** (optional, special field, must be its own `|`
  segment): matches the artist list against the raw Artist tag instead of
  AlbumArtist - see "Compilations / Various Artists" above. Default is
  `false` (original AlbumArtist-based behavior).
- **`sort=<key><+|-><key><+|->...`** (optional, special field, must be its
  own `|` segment): controls the track ORDER in the generated playlist
  instead of the default random shuffle.
  - Keys: `title`, `track`, `artist`, `album`, `year`, `added`,
    `originalyear`
  - `+` = ascending, `-` = descending; direction defaults to `+` if
    omitted (e.g. `sort=title` behaves like `sort=title+`)
  - Keys are concatenated directly with no separator, e.g.
    `sort=album-track+` sorts by album Z->A, then by track number 1->N
    within each album - a typical "grouped by album, tracks in order"
    listing. `sort=added+` puts the most recently added tracks first.
  - `sort=random` (or omitting `sort` entirely) keeps the original random
    order.
  - If the spec can't be parsed (e.g. a typo'd field name), the **whole**
    sort spec is discarded and the playlist falls back to random order -
    check the log for "Invalid sort spec" rather than getting a
    silently wrong partial sort.
- **`limit=N`** (optional, special field, must be its own `|` segment):
  caps the playlist at the first N tracks *after* filtering and sorting.
  Combine with `sort=` for "top N" style playlists, e.g.
  `sort=added+|limit=10` for "10 most recently added tracks", or
  `sort=duration-|limit=20` for "20 longest tracks". An invalid (non-
  numeric or zero) value is logged and ignored (no limit applied).

### Examples

```
# Simple: every track from these three artists
Genesis;Supertramp;Pink Floyd

# Custom playlist name
Classic Rock 70s::Genesis;Supertramp;Pink Floyd

# AND filters: no live albums, only 1973-1979
Classic Rock 70s::Genesis;Supertramp;Pink Floyd|album!~Live|year>=1973|year<=1979

# OR within a filter: title contains "Mix" OR album is exactly "12'' Ers"
Simply Red Mixes::Simply Red|title~Mix,album=12'' Ers

# Deduplicate: best-of and studio albums both in the library,
# but each song should only appear once
Queen Best-Of::Queen|duplicate=false

# Long tracks only
Long Tracks::Genesis|duration>300

# Sorted instead of shuffled: group by album (Z-A), tracks in order (1-N)
Genesis Albums In Order::Genesis|sort=album-track+

# Recently added tracks (based on file mtime), newest 15 only
New Genesis::Genesis|added<30|sort=added+|limit=15

# Genesis' own albums PLUS their compilation/guest appearances
# (AlbumArtist=Various Artists, Artist=Genesis on those tracks)
Genesis Everywhere::Genesis|various=true

# Compilation tracks only, regardless of artist
Various Artists Compilations::*|albumartist=VariousArtists

# Reissues: use the ORIGINAL release year, not the reissue year
70s Originals::*|originalyear>=1970|originalyear<1980

# Filter on a free-text Comment tag (e.g. "Remastered", "Live bootleg", ...)
Remastered Only::*|comment~Remaster

# Wildcard artist: library-wide, not tied to any specific artist,
# pulls from Internal Storage, USB, and NAS all at once
Recently Added (All Artists)::*|added<5|limit=20

# 30 random tracks from an artist: filters ALL matching tracks first,
# shuffles that whole set, then keeps the first 30 - a true random
# sample across the entire matching catalog, not just the first 30 found
Depeche Mode Mix::Depeche Mode|limit=30

# Combined: everything together
70s Rock, No Live Duplicates::Genesis;Supertramp;Pink Floyd|album!~Live|year>=1973|year<=1979|duplicate=false
```

## Usage

Manual run:
```bash
/usr/local/bin/volumio-smart-playlists.sh
```

Debug run (verbose trace to stderr):
```bash
DEBUG=1 bash -x /usr/local/bin/volumio-smart-playlists.sh 2> /tmp/debug.log
```

The script also writes its own log (with timestamps) to
`/data/smart_playlists_data/smart_playlists.debug.log` on every run,
independent of `DEBUG`. Follow it live during/after a run:
```bash
tail -f /data/smart_playlists_data/smart_playlists.debug.log
```

### Running on a schedule

You don't strictly need cron - Volumio uses systemd as its init system, so
systemd timers work too and don't require installing anything extra. Pick
whichever you're more comfortable with.

**Option A: cron**

Cron is usually already present on Volumio (it's Debian-based), but the
cron *service* is sometimes not enabled to start on boot - there are
several reports of this in the Volumio community. Check first:
```bash
crontab -l
systemctl status cron
```
If cron is present but not running/enabled:
```bash
sudo systemctl enable --now cron
```
Only if `cron`/`crontab` is genuinely missing:
```bash
sudo apt-get install -y cron
```

Then edit the system crontab:
```bash
sudo nano /etc/crontab
```
Add (daily at 3 AM):
```
0 3 * * * volumio /usr/local/bin/volumio-smart-playlists.sh >> /home/volumio/cron_playlists.log 2>&1
```

If `mpc` or `jq` live outside the default cron `PATH`, add a `PATH=`
line above your entry in `/etc/crontab`:
```
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**Option B: systemd timer**

No extra package needed, integrates with `journalctl` for logging, and -
unlike cron - can catch up on a missed run (e.g. if Volumio was off at
3 AM) instead of just skipping it.

```bash
sudo nano /etc/systemd/system/smart-playlists.service
```
```ini
[Unit]
Description=Volumio Smart Playlists

[Service]
Type=oneshot
User=volumio
ExecStart=/usr/local/bin/volumio-smart-playlists.sh
```

```bash
sudo nano /etc/systemd/system/smart-playlists.timer
```
```ini
[Unit]
Description=Run Volumio Smart Playlists daily at 3 AM

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now smart-playlists.timer
```

Check logging and next scheduled run:
```bash
journalctl -u smart-playlists.service
systemctl list-timers smart-playlists.timer
```

## How it stores playlists

Volumio 3 does **not** use `.m3u` files dropped into your music folder for
its native Playlist view - it reads JSON files from `/data/playlist/`
(one file per playlist, no file extension), each holding an array of track
objects like:
```json
{"service":"mpd","uri":"music-library/USB/Artist/Album/Track.flac","title":"...","artist":"...","album":"..."}
```
This script writes exactly that format directly, so playlists appear in
Volumio immediately, no import step required. See "How metadata is read"
above for how the `uri` differs between Internal Storage/USB and NAS.

## Notes / limitations

- Scanned extensions are configurable via the `AUDIO_EXTENSIONS` array
  near the top of the script. Default: `flac mp3 m4a dsf ogg opus aiff
  aif ape`. This only gates which files get an mtime entry (for change
  detection and the `added` filter) - metadata itself comes from MPD
  regardless of extension, but a file with no matching mtime entry never
  makes it into the cache. `.wav` and `.wma` are deliberately excluded by
  default - tagging conventions for those vary too much (RIFF INFO vs.
  ID3 chunks for WAV, inconsistent ASF tag usage for WMA) across encoders
  to trust blindly. Add your own extensions here if needed.
- `duplicate=false` deduplicates by title only (not artist+title), so two
  different artists with a coincidentally identical song title would
  collapse into one entry. For the intended use case (same artist,
  best-of vs. studio album) this is the desired behavior.
- Year comes from MPD's `Date` tag, `originalyear` from `OriginalDate` -
  in both cases the first 4 consecutive digits found in the tag, so both
  plain-year (`2023`) and full-date (`2023-01-01`) formats work.
- The artist-list header match and the `artist`/`albumartist` filter
  fields are all case-insensitive and ignore spaces/dashes/underscores/
  dots for `=`/`!=` comparisons (same normalization as everywhere else in
  this script) - "Various Artists" and "various-artists" are treated as
  identical.
- `added` is based on the file's mtime, not a real "date added to
  library" tag (no audio format reliably stores that). If you re-copy or
  re-tag a file later, its mtime - and therefore its `added` value -
  resets. An unclean USB disconnect/remount can also shift mtimes on some
  filesystems (exFAT via FUSE in particular), which shows up as every file
  looking "changed" on the next run - a one-off cost, not a bug, and it
  self-corrects after that run.
- OR-grouping via `,` inside a filter segment does not support escaping a
  literal comma in a value.
- The script does not delete tracks from the *audio library*, only manages
  the generated playlist files under `/data/playlist/`.
- Album art is not explicitly set in the generated JSON; Volumio typically
  resolves it automatically from the `uri` during playback.
- A disconnected/unreachable NAS share still counts as "available" if its
  mount directory exists locally, even if empty - you won't get an error,
  just 0 tracks from that source. Check `mount | grep cifs` and `dmesg` if
  NAS tracks are unexpectedly missing.

## Continuous play / AutoDJ (`volumio-autodj.sh`)

A separate, optional script that keeps Volumio's **play queue** topped up
automatically - unlike the main script above, which builds static
playlists, this one watches live playback and appends one similar track
once the queue is about to run out, for a radio-like "continuous play"
experience.

**Runs on a different device than Volumio** (a NAS, a Raspberry Pi, a PC -
anything on the same network), not on Volumio itself, and needs no SSH
access to Volumio at all - it only talks to Volumio over the network. **If
you DO have SSH access to Volumio**, use `volumio-autodj-local.sh` instead
- it runs directly on Volumio itself (scheduled the same way as
`volumio-smart-playlists.sh`) and is simpler, since it avoids the
cross-machine compatibility workaround described further below. See "If
you have SSH access" near the end of this section.

`volumio-autodj.sh` talks to Volumio over the network:
- Volumio's own REST API (`http://<volumio-ip>:3000/api/v1/...`) to read
  the current queue/playback state and to append tracks.
- Volumio's MPD instance (`<volumio-ip>:6600`) to check whether a
  candidate artist is present in your local library and to pick a track -
  this is normally already reachable over the LAN by default on Volumio
  (the same port third-party MPD clients like MPDroid use), no config
  change needed in the common case.
- The [Last.fm API](https://www.last.fm/api/account/create) (free API key)
  for "similar artist" suggestions.

### How it decides what to add

Each run does at most one check and, if needed, adds exactly one track:

1. Reads Volumio's current state and queue. Does nothing if playback isn't
   currently `play`, or if the number of tracks left after the current one
   is still at or above `QUEUE_LOW_THRESHOLD`.
2. Otherwise, takes the **artist of the last track currently in the
   queue** as the seed and asks Last.fm for similar artists (most similar
   first).
3. Tries each candidate in order until one is found in the local library
   (checked via `mpc list artist`) - and skips any candidate that was used
   too recently (**repeat guard**: a small history file of the last
   `HISTORY_SIZE` artists, so the same artist isn't picked again right
   away).
4. Picks one random track by the matched artist and appends it to the end
   of the queue via Volumio's `addToQueue` command.

This is deliberately simple/reactive (one track at a time, re-evaluated on
every run) rather than planning several tracks ahead - it naturally
"drifts" the similarity chain over time and needs no extra state beyond
the small repeat-guard history.

### Setup

1. Copy `volumio-autodj.sh` to the other device (not Volumio) and make it
   executable: `chmod +x volumio-autodj.sh`.
2. Requires `curl`, `jq`, `mpc`, and `nc` (netcat) on **that** device (not
   on Volumio) - `mpc` is only used for the simple `list artist` lookup;
   `nc` is used to speak MPD's own line protocol directly for the
   find/search step (see "Notes / limitations" below for why). `nc` is
   preinstalled on macOS and most Linux distributions; if missing, install
   `netcat-openbsd` (or equivalent).
3. Get a free Last.fm API key: https://www.last.fm/api/account/create
4. Run it periodically, e.g. every 1-2 minutes, via whatever scheduler the
   device it runs on has. Manual test run:
   ```bash
   VOLUMIO_HOST=192.168.1.50 LASTFM_API_KEY=xxxxxxxx ./volumio-autodj.sh
   ```
   - **Linux**: cron or a systemd timer - see "Running on a schedule"
     above for the general pattern (it applies the same way here, just
     pointed at `volumio-autodj.sh` on a different machine).
   - **macOS**: a `launchd` LaunchAgent. Save the following as
     `~/Library/LaunchAgents/com.volumio.autodj.plist` (adjust the paths,
     `VOLUMIO_HOST`, and `LASTFM_API_KEY` - `PATH` includes both
     Homebrew locations since launchd's own default `PATH` doesn't
     include Homebrew's `bin`, which is where `mpc`/`jq` normally live if
     installed via `brew install mpc jq`):
     ```xml
     <?xml version="1.0" encoding="UTF-8"?>
     <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
     <plist version="1.0">
     <dict>
         <key>Label</key>
         <string>com.volumio.autodj</string>

         <key>ProgramArguments</key>
         <array>
             <string>/bin/bash</string>
             <string>/Users/YOURUSERNAME/bin/volumio-autodj.sh</string>
         </array>

         <key>EnvironmentVariables</key>
         <dict>
             <key>PATH</key>
             <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
             <key>VOLUMIO_HOST</key>
             <string>192.168.1.50</string>
             <key>LASTFM_API_KEY</key>
             <string>xxxxxxxx</string>
         </dict>

         <key>StartInterval</key>
         <integer>90</integer>

         <key>RunAtLoad</key>
         <true/>

         <key>StandardOutPath</key>
         <string>/Users/YOURUSERNAME/Library/Logs/volumio-autodj.out.log</string>

         <key>StandardErrorPath</key>
         <string>/Users/YOURUSERNAME/Library/Logs/volumio-autodj.err.log</string>
     </dict>
     </plist>
     ```
     Then load it:
     ```bash
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.volumio.autodj.plist
     ```
     (On very old macOS versions where `bootstrap` isn't available, use
     `launchctl load -w ~/Library/LaunchAgents/com.volumio.autodj.plist`
     instead.) Check it's registered with
     `launchctl list | grep com.volumio.autodj`, and after editing the
     plist, unload (`launchctl bootout gui/$(id -u) ...` or
     `launchctl unload ...`) and load it again to pick up the change.
     `StartInterval` (seconds) is independent of - and typically shorter
     than - `QUEUE_LOW_THRESHOLD`'s own timing logic further below; the
     script itself decides on every run whether there's actually anything
     to do.

### Configuration (environment variables)

- `VOLUMIO_HOST` (required) - Volumio's IP/hostname.
- `LASTFM_API_KEY` (required) - your free Last.fm API key.
- `VOLUMIO_PORT` (default `3000`)
- `MPD_HOST` (default: same as `VOLUMIO_HOST`), `MPD_PORT` (default `6600`)
- `QUEUE_LOW_THRESHOLD` (default `3`) - refill once this few (or fewer)
  tracks remain after the currently playing one.
- `CANDIDATE_LIMIT` (default `20`) - how many similar artists to request
  from Last.fm per run.
- `HISTORY_SIZE` (default `15`) - how many recently-used artists the
  repeat guard remembers.
- `AUTODJ_URI_PREFIXES` - same idea/format as `SMART_PLAYLISTS_URI_PREFIXES`
  above (own variable, since this script runs on a separate machine).
  Default: `INTERNAL|music-library/`, `USB|music-library/`, `NAS|mnt/`.
- `AUTODJ_STATE_DIR` (default `~/.volumio-autodj`) - where the repeat-guard
  history and debug log are stored, on the device this script runs on.

### Notes / limitations

- Only handles **appending** to the queue - it never removes or reorders
  existing entries, so manual changes you make in the meantime are never
  overwritten.
- If none of the `CANDIDATE_LIMIT` similar artists for the current seed are
  in your local library, the run simply does nothing that time - it tries
  again with a (likely different) seed on the next scheduled run once the
  queue moves on. If candidates ARE in your library but every one of them
  was filtered by the repeat guard, the repeat guard is overridden as a
  fallback and the most-similar recently-used artist is picked anyway
  (still a freshly-randomized track of theirs) - letting playback stop
  entirely would be worse than an occasional early repeat.
- The Last.fm similarity graph can drift fairly far from the original
  artist over a long listening session, since each new seed is just "the
  last queued artist" with no anchoring back to where you started. Nothing
  in this script currently corrects for that.
- Debug log at `$AUTODJ_STATE_DIR/autodj.debug.log` on the device this
  script runs on.
- **Why `nc` instead of just `mpc find`/`mpc search`**: newer mpc/
  libmpdclient releases (e.g. the one Homebrew installs on macOS) send a
  `tagtypes ...` protocol negotiation command before running `find`/
  `search`, which requires MPD protocol 0.21+. Volumio's own bundled MPD
  is often older than that and rejects it outright (`MPD error: wrong
  number of arguments for "tagtypes"`), which makes `mpc find`/`mpc
  search` fail completely against Volumio - even for an artist that
  genuinely is in the library - whenever this script runs on a machine
  with a newer `mpc` than Volumio's MPD supports. (Same class of bug
  reported here for another MPD-protocol server:
  https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1002544.) The
  find/search step therefore talks to MPD's line protocol directly over a
  raw TCP connection (via `nc`), bypassing mpc/libmpdclient - and with it,
  that whole class of version-negotiation incompatibility - entirely. The
  simpler `mpc list artist` lookup elsewhere in the script is unaffected
  and still uses `mpc` normally.

### If you have SSH access: run it locally instead (`volumio-autodj-local.sh`)

Everything above describes `volumio-autodj.sh`, which is designed to run
on a **different** device because it assumes no SSH access to Volumio. If
you do have SSH access, `volumio-autodj-local.sh` is a simpler alternative
that runs directly **on** Volumio itself - same behavior and
configuration variables (`LASTFM_API_KEY`, `QUEUE_LOW_THRESHOLD`,
`CANDIDATE_LIMIT`, `HISTORY_SIZE`, `AUTODJ_URI_PREFIXES`), with these
differences:

- `VOLUMIO_HOST`/`MPD_HOST` default to `localhost` instead of being
  required - no IP/hostname to configure in the common case.
- No `nc` dependency and no raw-protocol workaround: it uses plain `mpc
  find`/`mpc search` directly. The version-mismatch problem described
  above only happens when an *independently installed* mpc talks to
  Volumio's MPD over the network - Volumio's own bundled `mpc` always
  matches its own bundled MPD, so that failure mode can't occur here.
- `AUTODJ_STATE_DIR` defaults to `/data/volumio_autodj_data` instead of
  `~/.volumio-autodj`, matching where `volumio-smart-playlists.sh` keeps
  its own state (deliberately under `/data/`, not tied to a particular
  user's home directory).

**Setup:**

1. Copy `volumio-autodj-local.sh` to Volumio (e.g.
   `/usr/local/bin/volumio-autodj-local.sh`) and make it executable:
   `sudo chmod +x /usr/local/bin/volumio-autodj-local.sh`.
2. Requires `curl`, `jq`, and `mpc` - `mpc` is part of Volumio's base
   image already; install `jq` if needed (see "Requirements" above).
3. Get a free Last.fm API key: https://www.last.fm/api/account/create
4. Schedule it every 1-2 minutes via cron or a systemd timer - see
   "Running on a schedule" above for the exact steps (cron entry or
   systemd `.service`/`.timer` files), just pointed at
   `volumio-autodj-local.sh` and with `LASTFM_API_KEY` set, e.g. as a
   `PATH`-style variable line above the crontab entry:
   ```
   LASTFM_API_KEY=xxxxxxxx
   */2 * * * * volumio /usr/local/bin/volumio-autodj-local.sh >> /home/volumio/autodj_cron.log 2>&1
   ```

## Upgrading from an earlier version

This script has gone through a few naming/location and architecture
changes:
- `build_artist_playlists.sh` / `artists_playlists.txt` / `.track_cache.tsv`
  → renamed to `volumio-smart-playlists.sh` / `smart_playlists.txt` /
  `.smart_playlists_cache.tsv`
- Single-source config (`MUSIC_DIR`/`MPD_ROOT`/`MPD_SOURCE_LABEL`, working
  files stored inside your music folder) → automatic multi-source scanning,
  working files moved to `/data/smart_playlists_data/`
- Per-file `exiftool` scanning with an incremental cache → metadata read
  directly from Volumio's own MPD (see "How metadata is read" above);
  `exiftool` is no longer a dependency at all. `bpm` is no longer a
  supported filter field (MPD has no BPM tag).

If you're on an old version, the cleanest path is to delete the old cache
file (wherever it was) and let the current version rebuild it fresh in its
new location - trying to migrate the old cache format isn't worth the
effort. Your existing rules just need to be copied into the new
`smart_playlists.txt` location. A `bpm` filter in an existing rule line is
simply ignored going forward (logged as an unknown field) rather than
causing an error.

- **AlbumArtist/Artist/OriginalDate/Comment support** (this version): the
  cache format gained new columns (Artist is now read separately from
  AlbumArtist, plus OriginalYear and Comment) and the `artist` filter
  field now means the raw Artist tag rather than AlbumArtist-with-
  fallback (use `albumartist` for the old meaning). No manual step is
  needed for the cache itself - it's rebuilt from scratch on every run
  regardless of version, so the new columns simply appear on the next
  run. If you want to use `comment` filters, add `comment` to mpd.conf's
  `metadata_to_use` and rebuild MPD's database first (see "How metadata
  is read" above) - without that change, `comment` will just always be
  empty.

## License

Do whatever you want with it.
