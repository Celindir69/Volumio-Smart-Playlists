#!/usr/bin/env bash
# =============================================================================
# Volumio AutoDJ / Continuous Play
#
# Runs on a SEPARATE device on the same network as Volumio (NOT on Volumio
# itself - no SSH access to Volumio required). Watches Volumio's play queue
# via its REST API; once it's about to run out, picks a similar artist to
# the last queued track (via the Last.fm API), checks whether that artist
# is present in the local library (via MPD, queried over the network), and
# if so appends one random track by that artist to the end of the queue.
#
# Intended to be run periodically (e.g. every 1-2 minutes) via cron or a
# systemd timer ON THE DEVICE THIS SCRIPT RUNS ON - it does not loop or
# schedule itself. Each invocation does at most one queue check and, if
# needed, adds exactly one track.
#
# Simple repeat guard: the last HISTORY_SIZE artists that were added (or
# used as a seed) are remembered in a small history file, and skipped when
# picking a candidate, so the same artist isn't immediately re-picked over
# and over.
# =============================================================================
set -euo pipefail

export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------
VOLUMIO_HOST="${VOLUMIO_HOST:?Set VOLUMIO_HOST to the Volumio devices IP/hostname}"
VOLUMIO_PORT="${VOLUMIO_PORT:-3000}"

# MPD is queried directly (not through Volumio's REST API, which has no
# "does this artist exist locally / list their tracks" endpoint) to check
# whether a similar-artist candidate is actually in your library and to
# pick a track. Defaults to the same host as Volumio, since Volumio's own
# MPD is normally what you want. Requires MPD to be reachable on the
# network (not just localhost) - check `grep bind_to_address /etc/mpd.conf`
# on Volumio if this fails to connect; that one setting still needs to be
# changed on Volumio itself, but that's a one-time config edit, not what
# this script (or its scheduling) needs SSH for on an ongoing basis.
MPD_HOST="${MPD_HOST:-$VOLUMIO_HOST}"
MPD_PORT="${MPD_PORT:-6600}"

LASTFM_API_KEY="${LASTFM_API_KEY:?Set LASTFM_API_KEY to a free Last.fm API key (https://www.last.fm/api/account/create)}"

# How many tracks may still be left AFTER the currently playing one before
# a refill is triggered (0 = only refill once the queue is truly empty
# after the current track).
QUEUE_LOW_THRESHOLD="${QUEUE_LOW_THRESHOLD:-3}"

# How many similar artists to request from Last.fm per run - the script
# tries them in order (most similar first) until one is found locally.
CANDIDATE_LIMIT="${CANDIDATE_LIMIT:-20}"

# How many recently-used artists to remember for the repeat guard.
HISTORY_SIZE="${HISTORY_SIZE:-15}"

# Same idea as SMART_PLAYLISTS_URI_PREFIXES in volumio-smart-playlists.sh -
# maps the first path segment MPD reports for a track to the prefix needed
# to build a Volumio playlist/queue "uri". Kept independent (own env var)
# since this script runs on a different machine and has no access to the
# other script's config.
AUTODJ_URI_PREFIXES_DEFAULT="INTERNAL|music-library/
USB|music-library/
NAS|mnt/"
URI_PREFIXES_RAW="${AUTODJ_URI_PREFIXES:-$AUTODJ_URI_PREFIXES_DEFAULT}"

STATE_DIR="${AUTODJ_STATE_DIR:-$HOME/.volumio-autodj}"
HISTORY_FILE="$STATE_DIR/history.txt"
DEBUG_LOG="$STATE_DIR/autodj.debug.log"

mkdir -p "$STATE_DIR"

if [[ -f "$DEBUG_LOG" ]] && (( $(stat -c%s "$DEBUG_LOG" 2>/dev/null || stat -f%z "$DEBUG_LOG" 2>/dev/null || echo 0) > 2097152 )); then
  mv -f "$DEBUG_LOG" "${DEBUG_LOG}.1"
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$DEBUG_LOG" >&2
}

for tool in curl jq mpc nc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: '$tool' is required but not found" >&2
    exit 1
  fi
done

normalize() {
  # NOTE: the "-" must come LAST in the tr -d set below - "tr -d ' -_.'"
  # would make tr treat "space-underscore" as a RANGE (0x20-0x5F), which
  # silently deletes digits and punctuation too (e.g. "U2" -> "u",
  # "3 Doors Down" -> "doorsdown"). Placing "-" last keeps it literal.
  printf '%s' "$1" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d ' _.-'
}

urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

# ---------------------------------------------------------------------------
# Repeat guard: newline-separated, normalized artist names, most recent
# last, capped at HISTORY_SIZE entries.
# ---------------------------------------------------------------------------
history_contains() {
  local norm_name="$1"
  [[ -f "$HISTORY_FILE" ]] || return 1
  grep -qxF "$norm_name" "$HISTORY_FILE"
}

history_add() {
  local norm_name="$1"
  touch "$HISTORY_FILE"
  # Drop any existing occurrence first so a re-added artist moves to the
  # end (most-recent) instead of creating a duplicate line.
  grep -vxF "$norm_name" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null || true
  mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
  printf '%s\n' "$norm_name" >> "$HISTORY_FILE"
  # Keep only the last HISTORY_SIZE lines.
  tail -n "$HISTORY_SIZE" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
  mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

# ---------------------------------------------------------------------------
# 1. Check Volumio's current playback state and queue.
# ---------------------------------------------------------------------------
api_base="http://${VOLUMIO_HOST}:${VOLUMIO_PORT}/api/v1"

state_json="$(curl -sf --max-time 10 "${api_base}/getstate")" || {
  log "Could not reach Volumio's REST API at $api_base (getstate) - is VOLUMIO_HOST/VOLUMIO_PORT correct?"
  exit 1
}
status="$(printf '%s' "$state_json" | jq -r '.status // empty')"

if [[ "$status" != "play" ]]; then
  log "Volumio status is '$status' (not 'play') - nothing to do"
  exit 0
fi

queue_json="$(curl -sf --max-time 10 "${api_base}/getqueue")" || {
  log "Could not reach Volumio's REST API at $api_base (getqueue)"
  exit 1
}

position="$(printf '%s' "$state_json" | jq -r '.position // 0')"
queue_len="$(printf '%s' "$queue_json" | jq -r '.queue | length')"
remaining=$(( queue_len - position - 1 ))

log "Queue: $queue_len tracks, position=$position, remaining after current=$remaining (threshold=$QUEUE_LOW_THRESHOLD)"

if (( remaining >= QUEUE_LOW_THRESHOLD )); then
  log "Enough tracks remaining - nothing to do"
  exit 0
fi

if (( queue_len == 0 )); then
  log "Queue is empty - nothing to seed from, nothing to do"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Pick a seed artist: the last track currently in the queue.
# ---------------------------------------------------------------------------
seed_artist="$(printf '%s' "$queue_json" | jq -r '.queue[-1].artist // empty')"

if [[ -z "$seed_artist" ]]; then
  log "Last queue entry has no artist tag - can't pick a seed, nothing to do"
  exit 0
fi

log "Seed artist: $seed_artist"
norm_seed="$(normalize "$seed_artist")"
history_add "$norm_seed"

# ---------------------------------------------------------------------------
# 3. Ask Last.fm for similar artists (most similar first).
# ---------------------------------------------------------------------------
lastfm_url="http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar&artist=$(urlencode "$seed_artist")&api_key=${LASTFM_API_KEY}&format=json&limit=${CANDIDATE_LIMIT}"
lastfm_json="$(curl -sf --max-time 10 "$lastfm_url")" || {
  log "Last.fm request failed"
  exit 1
}

lastfm_error="$(printf '%s' "$lastfm_json" | jq -r '.message // empty')"
if [[ -n "$lastfm_error" ]]; then
  log "Last.fm returned an error: $lastfm_error"
  exit 1
fi

# "mapfile"/"readarray" needs bash 4.0+, which isn't a given on every
# device this script might run on (e.g. macOS still ships bash 3.2 by
# default) - a plain "while read" loop works on any bash version instead.
candidates=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  candidates+=("$line")
done < <(printf '%s' "$lastfm_json" | jq -r '.similarartists.artist[]?.name // empty')

if (( ${#candidates[@]} == 0 )); then
  log "Last.fm returned no similar artists for '$seed_artist'"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Try each candidate, most similar first, until one is found locally
#    (via MPD's artist list) and isn't in the repeat-guard history.
# ---------------------------------------------------------------------------
local_artists=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  local_artists+=("$line")
done < <(mpc -h "$MPD_HOST" -p "$MPD_PORT" list artist 2>>"$DEBUG_LOG")

if (( ${#local_artists[@]} == 0 )); then
  log "Could not read the local artist list from MPD ($MPD_HOST:$MPD_PORT) - is it reachable? (check bind_to_address in Volumio's mpd.conf)"
  exit 1
fi

# Parallel arrays instead of "declare -A" (associative arrays also need
# bash 4.0+, same as mapfile above) - normalized name in local_norm[i]
# maps to the real, as-tagged name in local_real[i] at the same index.
local_norm=()
local_real=()
for a in "${local_artists[@]}"; do
  [[ -z "$a" ]] && continue
  local_norm+=("$(normalize "$a")")
  local_real+=("$a")
done

find_local_artist() {
  local target="$1" i
  for (( i = 0; i < ${#local_norm[@]}; i++ )); do
    if [[ "${local_norm[$i]}" == "$target" ]]; then
      printf '%s' "${local_real[$i]}"
      return 0
    fi
  done
  return 1
}

chosen_artist=""
for cand in "${candidates[@]}"; do
  [[ -z "$cand" ]] && continue
  norm_cand="$(normalize "$cand")"
  if history_contains "$norm_cand"; then
    log "Skipping '$cand' (recently used, repeat guard)"
    continue
  fi
  if real_match="$(find_local_artist "$norm_cand")"; then
    chosen_artist="$real_match"
    log "Match found in local library: '$cand' -> '$chosen_artist'"
    break
  fi
done

if [[ -z "$chosen_artist" ]]; then
  log "None of the ${#candidates[@]} similar artists for '$seed_artist' are in the local library (or all were filtered by the repeat guard)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Pick one random track by that artist and build its Volumio queue uri.
# ---------------------------------------------------------------------------
# NOTE: this deliberately does NOT use "mpc find"/"mpc search". Newer mpc/
# libmpdclient releases (e.g. Homebrew's on macOS) send a "tagtypes ..."
# protocol negotiation command before running find/search, which requires
# MPD protocol 0.21+ - Volumio's own (much older, heavily patched) bundled
# MPD rejects it outright ("MPD error: wrong number of arguments for
# 'tagtypes'"), so "mpc find"/"mpc search" fail completely against Volumio
# whenever this script runs on a machine with a newer mpc than Volumio's
# MPD supports, even for an artist that unmistakably IS in the library
# (confirmed via "mpc list artist" just above). Same class of bug reported
# here for another MPD-protocol server:
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1002544
#
# Talking to MPD's line protocol directly via "nc" sidesteps mpc/
# libmpdclient (and its negotiation) entirely, so it works regardless of
# how old Volumio's bundled MPD is.
norm_chosen="$(normalize "$chosen_artist")"

mpd_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Sends one command over a fresh MPD connection and prints the raw
# response. "close" tells MPD to close the connection once it has sent
# the reply, so "nc" exits on its own instead of needing a fixed wait.
mpd_raw_query() {
  printf '%s\nclose\n' "$1" | nc -w 10 "$MPD_HOST" "$MPD_PORT" 2>>"$DEBUG_LOG"
}

# Parses a find/search response (repeated "file: ..." blocks, each with
# assorted "Tag: value" lines) and appends the path of every block whose
# Artist line normalizes to exactly the target artist. The post-filter
# matters for "search" (substring match) - without it, an unrelated
# artist whose name merely contains this one as a substring would also
# match; it's a harmless no-op for "find" (exact match).
collect_files_by_artist() {
  local verb="$1" cur_file="" cur_artist="" line
  while IFS= read -r line; do
    case "$line" in
      "file: "*)
        if [[ -n "$cur_file" && "$(normalize "$cur_artist")" == "$norm_chosen" ]]; then
          files+=("$cur_file")
        fi
        cur_file="${line#file: }"
        cur_artist=""
        ;;
      "Artist: "*)
        cur_artist="${line#Artist: }"
        ;;
      "ACK "*)
        log "MPD returned an error for '$verb artist \"$chosen_artist\"': $line"
        ;;
    esac
  done < <(mpd_raw_query "$verb artist $(mpd_quote "$chosen_artist")")
  if [[ -n "$cur_file" && "$(normalize "$cur_artist")" == "$norm_chosen" ]]; then
    files+=("$cur_file")
  fi
}

files=()
collect_files_by_artist find

if (( ${#files[@]} == 0 )); then
  log "MPD 'find artist \"$chosen_artist\"' returned nothing despite appearing in 'mpc list artist' - retrying with 'search' instead"
  collect_files_by_artist search
fi

if (( ${#files[@]} == 0 )); then
  log "No files found for '$chosen_artist' via 'find' or 'search' - skipping (check $DEBUG_LOG for MPD errors, or try manually: printf 'find artist \"%s\"\\nclose\\n' | nc $MPD_HOST $MPD_PORT)"
  exit 0
fi

picked_file="${files[$(( RANDOM % ${#files[@]} ))]}"

uri=""
label="${picked_file%%/*}"
while IFS='|' read -r lbl pfx; do
  [[ -z "$lbl" ]] && continue
  if [[ "$lbl" == "$label" ]]; then
    uri="${pfx}${picked_file}"
    break
  fi
done <<< "$URI_PREFIXES_RAW"

if [[ -z "$uri" ]]; then
  log "No configured uri prefix for source label '$label' (path: $picked_file) - set AUTODJ_URI_PREFIXES; skipping"
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Append it to Volumio's queue.
# ---------------------------------------------------------------------------
add_url="${api_base}/commands/?cmd=addToQueue&uri=$(urlencode "$uri")"
add_response="$(curl -sf --max-time 10 "$add_url")" || {
  log "addToQueue request failed for uri '$uri'"
  exit 1
}

log "Added '$picked_file' (artist: $chosen_artist) to the queue - response: $add_response"
history_add "$(normalize "$chosen_artist")"
