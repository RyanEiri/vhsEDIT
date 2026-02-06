#!/usr/bin/env bash
#
# vhs_stabilize.sh
#
# Audio denoise step (non-destructive).
#
# Defaults (no args):
#   IN :  ~/Videos/captures/archival/<newest>.mkv
#   OUT:  ~/Videos/captures/stabilized/<stem>_STABLE.mkv
#
# Usage:
#   vhs_stabilize.sh
#   vhs_stabilize.sh INPUT.mkv
#   vhs_stabilize.sh INPUT.mkv OUTPUT.mkv
#   vhs_stabilize.sh INPUT.mkv OUTPUT.mkv [NOISE_SS] [NOISE_T] [NR_AMOUNT] [NORM_DB] [THREADS]
#
# Environment overrides:
#   FORCE=1            overwrite outputs (default: 0)
#   DENOISE_SH         path to denoise.sh (default: ~/Videos/denoise.sh, else ./denoise.sh)
#   DENOISE_PRESET     light|medium|heavy (default: light)
#   NOISE_SS           noise sample start (default: 00:00:00)
#   NOISE_T            noise sample duration (default: 00:00:01.0)
#   NR_AMOUNT          noise reduction amount (default: 0.12)
#   NORM_DB            normalization dB (default: -2)
#   FFMPEG_THREADS     ffmpeg threads (default: nproc)
#
set -euo pipefail

VIDEOS="${HOME}/Videos"
CAPTURES="${VIDEOS}/captures"
ARCHIVAL="${CAPTURES}/archival"
STABILIZED="${CAPTURES}/stabilized"
VIEWER="${CAPTURES}/viewer"

newest_mkv() {
  local dir="$1"
  ls -1t "$dir"/*.mkv 2>/dev/null | head -n 1
}

stem_of() {
  local f; f="$(basename "$1")"
  echo "${f%.mkv}"
}

ensure_dir() {
  [[ -d "$1" ]] || mkdir -p "$1"
}

out_or_skip() {
  local out="$1" force="${2:-0}"
  if [[ -e "$out" && "$force" != "1" ]]; then
    echo "Exists, skipping (FORCE=1 to overwrite): $out" >&2
    return 1
  fi
  return 0
}

FFMPEG_BIN="/usr/bin/ffmpeg"
FORCE="${FORCE:-0}"

DENOISE_SH="${DENOISE_SH:-$HOME/Videos/denoise.sh}"
[[ -x "$DENOISE_SH" ]] || DENOISE_SH="$(cd "$(dirname "$0")" && pwd)/denoise.sh"
[[ -x "$DENOISE_SH" ]] || { echo "ERROR: denoise.sh not found/executable (set DENOISE_SH)" >&2; exit 1; }

# --- Defaults (lighter touch) ---
DENOISE_PRESET="${DENOISE_PRESET:-light}"

# Base defaults (can be overridden by preset and/or env and/or args)
NOISE_SS="${NOISE_SS:-00:00:00}"
NOISE_T="${NOISE_T:-00:00:01.0}"
NR_AMOUNT="${NR_AMOUNT:-0.12}"
NORM_DB="${NORM_DB:--2}"
FFMPEG_THREADS="${FFMPEG_THREADS:-$(nproc)}"

# Preset layer (only applies if user didn't explicitly set env vars)
# Note: if you set NOISE_T/NR_AMOUNT/NORM_DB in env, those win.
case "$DENOISE_PRESET" in
  light)
    : "${NOISE_T:=00:00:01.0}"
    : "${NR_AMOUNT:=0.12}"
    : "${NORM_DB:=-2}"
    ;;
  medium)
    : "${NOISE_T:=00:00:01.0}"
    : "${NR_AMOUNT:=0.16}"
    : "${NORM_DB:=-1}"
    ;;
  heavy)
    : "${NOISE_T:=00:00:00.8}"
    : "${NR_AMOUNT:=0.22}"
    : "${NORM_DB:=-1}"
    ;;
  *)
    echo "ERROR: unknown DENOISE_PRESET='$DENOISE_PRESET' (use light|medium|heavy)" >&2
    exit 1
    ;;
esac

if [[ $# -ge 1 ]]; then IN="$1"; else IN="$(newest_mkv "$ARCHIVAL")"; fi
[[ -n "${IN:-}" ]] || { echo "ERROR: no input found in $ARCHIVAL" >&2; exit 1; }
[[ -f "$IN" ]] || { echo "ERROR: input not found: $IN" >&2; exit 1; }

stem="$(stem_of "$IN")"
ensure_dir "$STABILIZED"
if [[ $# -ge 2 ]]; then OUT="$2"; else OUT="$STABILIZED/${stem}_$(date +%H-%M-%S)_STABLE.mkv"; fi

# Positional args override everything (as before)
if [[ $# -ge 3 ]]; then NOISE_SS="$3"; fi
if [[ $# -ge 4 ]]; then NOISE_T="$4"; fi
if [[ $# -ge 5 ]]; then NR_AMOUNT="$5"; fi
if [[ $# -ge 6 ]]; then NORM_DB="$6"; fi
if [[ $# -ge 7 ]]; then FFMPEG_THREADS="$7"; fi

if ! out_or_skip "$OUT" "$FORCE"; then
  echo "$OUT"
  exit 0
fi

echo "Stabilize step (delegating to denoise.sh)"
echo "  Input:   $IN"
echo "  Output:  $OUT"
echo "  PRESET:  $DENOISE_PRESET"
echo "  SS:      $NOISE_SS"
echo "  T:       $NOISE_T"
echo "  NR:      $NR_AMOUNT"
echo "  NORM:    $NORM_DB"
echo "  THREADS: $FFMPEG_THREADS"
echo

"$DENOISE_SH" "$IN" "$OUT" "$NOISE_SS" "$NOISE_T" "$NR_AMOUNT" "$NORM_DB" "$FFMPEG_THREADS"

echo
echo "$OUT"

