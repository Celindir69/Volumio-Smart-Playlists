# Volumio Smart Playlists

A bash script for Volumio 3 that automatically builds native Volumio playlists
from a plain text file of rules - artist lists with optional AND/OR filters on
album, genre, year, title, track number, duration, and BPM, plus optional
deduplication of repeated tracks (e.g. when a best-of/live compilation and the
original studio album are both in your library).

Tested with a ~24,000 track FLAC/MP3/M4A library on a USB drive attached to
Volumio 3.

## What it does

- Reads a text file where each line describes one playlist you want built
  (artist name(s), optionally with filters).
- Reads metadata (AlbumArtist, Artist, Title, Album, Genre, Year, Track,
  Duration, BPM) from your music files via `exiftool`, with an **incremental
  cache**: only new or changed files are re-scanned on subsequent runs, so a
  library of tens of thousands of tracks that would take ~20 minutes to scan
  the first time only takes seconds on later runs if just a handful of files
  changed.
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

- Volumio 3
- `exiftool` and `jq` installed:
  ```bash
  sudo apt-get update
  sudo apt-get install -y libimage-exiftool-perl jq
  ```

## Installation

1. Download `volumio-smart-playlists.sh` and copy it to your Volumio device,
   e.g. `/usr/local/bin/volumio-smart-playlists.sh`.
2. Make it executable:
   ```bash
   sudo chmod +x /usr/local/bin/volumio-smart-playlists.sh
   ```
3. **Edit the configuration block at the top of the script** to match your
   setup:
   ```bash
   MUSIC_DIR="/media/MX-Media"      # your music folder
   MPD_ROOT="/media"                # the mount root Volumio/MPD sees
   MPD_SOURCE_LABEL="USB"           # the source label Volumio shows in Browse
   ```
   To find the right values for your system:
   - `MUSIC_DIR` is wherever your music actually lives - check with
     `mount` or `df -h` on your Volumio device (USB drives are commonly
     mounted under `/media/<label>`, network shares under `/mnt/<label>`).
   - `MPD_ROOT` is the parent directory Volumio treats as its music root
     (usually `/media` or `/mnt`, one level above your music folder).
   - `MPD_SOURCE_LABEL` is the name Volumio uses internally for this
     source. The easiest way to find it: create *any* playlist manually in
     the Volumio UI, then inspect the resulting file under
     `/data/playlist/` - the `uri` field looks like
     `music-library/<SOURCE_LABEL>/<path>/track.flac`. Whatever comes
     right after `music-library/` is your `MPD_SOURCE_LABEL`.

## Input file format

Create `Playlists/smart_playlists.txt` inside your music folder (i.e.
`$MUSIC_DIR/Playlists/smart_playlists.txt`). One line per playlist:

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
  with OR (a track matches if its AlbumArtist matches *any* of them).
  Matching is case-insensitive and ignores spaces/dashes/underscores/dots.
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
  - Fields: `album`, `genre`, `year`, `title`, `artist`, `track`,
    `duration` (seconds), `bpm`, `added` (days since the file's mtime -
    see caveat below)
  - Operators: `=`, `!=`, `~` (contains), `!~` (does not contain), `>`,
    `>=`, `<`, `<=`
  - Numeric comparisons (`>`, `>=`, `<`, `<=`) apply to `year`, `track`,
    `duration`, `bpm`, and `added`.
  - Note: if a value legitimately contains a comma, it will be
    mis-parsed as an OR split - this is a known limitation.
- **`duplicate=false`** (optional, special field, must be its own `|`
  segment): deduplicates the resulting playlist by normalized track title,
  keeping only the first match per title. Default is `true` (duplicates
  allowed, i.e. original behavior).
- **`sort=<key><+|-><key><+|->...`** (optional, special field, must be its
  own `|` segment): controls the track ORDER in the generated playlist
  instead of the default random shuffle.
  - Keys: `title`, `track`, `artist`, `album`, `year`, `added`
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

# Fast, long tracks
Long Uptempo::Genesis|duration>300|bpm>=120

# Sorted instead of shuffled: group by album (Z-A), tracks in order (1-N)
Genesis Albums In Order::Genesis|sort=album-track+

# Recently added tracks (based on file mtime), newest 15 only
New Genesis::Genesis|added<30|sort=added+|limit=15

# Wildcard artist: library-wide, not tied to any specific artist
Recently Added (All Artists)::*|added<5|limit=20

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
`$MUSIC_DIR/Playlists/smart_playlists.debug.log` on every run, independent
of `DEBUG`.

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

If `exiftool` or `jq` live outside the default cron `PATH`, add a `PATH=`
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
Volumio immediately, no import step required.

## Notes / limitations

- Scanned extensions are configurable via the `AUDIO_EXTENSIONS` array
  near the top of the script. Default: `flac mp3 m4a dsf ogg opus aiff
  aif ape` - formats with well-established, reliably read metadata via
  exiftool (ID3 for mp3/dsf/aiff, Vorbis comments for flac/ogg/opus,
  APEv2 for ape, MP4 atoms for m4a). `.wav` and `.wma` are deliberately
  excluded by default - tagging conventions for those vary too much
  (RIFF INFO vs. ID3 chunks for WAV, inconsistent ASF tag usage for WMA)
  to trust blindly. If you want to add them (or anything else), test
  first with `exiftool -AlbumArtist -Artist yourfile.ext` to confirm it
  actually returns something sensible for your files.
- `duplicate=false` deduplicates by title only (not artist+title), so two
  different artists with a coincidentally identical song title would
  collapse into one entry. For the intended use case (same artist,
  best-of vs. studio album) this is the desired behavior.
- Year is read from `-Year`, falling back to `-Date`, falling back to
  `-ContentCreateDate` (the QuickTime "©day" atom iTunes-tagged M4A files
  often use instead) - in that order.
- `added` is based on the file's mtime, not a real "date added to
  library" tag (no audio format reliably stores that). If you re-copy or
  re-tag a file later, its mtime - and therefore its `added` value -
  resets.
- OR-grouping via `,` inside a filter segment does not support escaping a
  literal comma in a value.
- The script does not delete tracks from the *audio library*, only manages
  the generated playlist files under `/data/playlist/`.
- Album art is not explicitly set in the generated JSON; Volumio typically
  resolves it automatically from the `uri` during playback.

## Upgrading from an earlier version

If you're upgrading from a version of this script that used
`build_artist_playlists.sh` / `artists_playlists.txt` / `.track_cache.tsv`:
rename your existing input file to `smart_playlists.txt`, and either rename
your existing `.track_cache.tsv` to `.smart_playlists_cache.tsv` (to keep
the incremental cache and avoid a full rescan) or just let the script
rebuild it from scratch on the next run.

## License

Do whatever you want with it.
