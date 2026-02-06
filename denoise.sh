#!/usr/bin/env bash
# denoise.sh
#
# Sync-safe audio line-noise reduction using the same methodology you have been
# using successfully: prep audio (HPF/rebase/48k) and pass through.
#
# Key difference vs the older "denoise.sh" in your stabilize stage:
#   - Output audio codec matches the archival master (PCM).
#   - No AAC encoding (avoids encoder delay/priming and drift).
#
# INPUT : archival/intermediate MKV (e.g., FFV1/PCM MKV)
# OUTPUT: MKV with video stream copied and audio denoised to PCM (pcm_s16le)
#
# Usage:
#   denoise.sh INPUT OUTPUT [noise_start] [noise_duration] [nr_amount] [norm_db] [threads]
#
# Args (compatible with your existing wrapper expectations):
#   noise_start    default 00:00:00
#   noise_duration default 00:00:00.3
#   nr_amount      default 0.20    (SoX noisered amount; 0.10–0.35 typical)
#   norm_db        default -1      (SoX norm target in dBFS; empty disables)
#   threads        default $(nproc) (used for ffmpeg -threads)
#
set -euo pipefail

usage() {
  cat <<'USAGE'
USAGE:
  denoise.sh INPUT OUTPUT [noise_start] [noise_duration] [nr_amount] [norm_db] [threads]

Example:
  denoise.sh in.mkv out.mkv 00:00:02 00:00:00.6 0.18 -1

Notes:
  - This script always outputs PCM (pcm_s16le) and copies video bit-exact.
  - If NOISERED_ENABLE=1, it builds a noise profile from the sample window and applies noisered.
  - If your source audio is not 48 kHz stereo, it is converted to 48 kHz stereo
    for consistent processing and NLE friendliness.
USAGE
}

if [[ $# -lt 2 ]]; then usage; exit 1; fi

IN=$1
OUT=$2
SS=${3:-00:00:00}
T=${4:-00:00:00.3}
NR=${5:-0.20}

NORM_DB=${6:-off}          # default OFF
THREADS=${7:-$(nproc)}

# Defaults: HPF + timestamp rebase + 48k stereo coercion
HPF_ENABLE="${HPF_ENABLE:-1}"
HPF_HZ="${HPF_HZ:-20}"

TS_REBASE="${TS_REBASE:-1}"     # default ON
FORCE_AR="${FORCE_AR:-48000}"   # default ON (48 kHz)
FORCE_AC="${FORCE_AC:-2}"       # default ON (stereo)

NOISERED_ENABLE="${NOISERED_ENABLE:-0}"   # default OFF

[[ -f "$IN" ]] || { echo "ERROR: Input not found: $IN" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

FFMPEG_BIN=${FFMPEG_BIN:-$(command -v ffmpeg || true)}
SOX_BIN=${SOX_BIN:-$(command -v sox || true)}

if [[ -z "$FFMPEG_BIN" || ! -x "$FFMPEG_BIN" ]]; then
  echo "ERROR: ffmpeg not found in PATH (set FFMPEG_BIN)" >&2
  exit 1
fi
if [[ -z "$SOX_BIN" || ! -x "$SOX_BIN" ]]; then
  echo "ERROR: sox not found in PATH. Install with: sudo apt-get install sox" >&2
  exit 1
fi

REBASING_MODE="${REBASING_MODE:-soft}"  # soft|hard|off
AF_CHAIN=()

if [[ "$HPF_ENABLE" == "1" ]]; then
  AF_CHAIN+=("highpass=f=${HPF_HZ}")
fi

if [[ "$TS_REBASE" == "1" ]]; then
  case "$REBASING_MODE" in
    off)
      ;;
    soft)
      AF_CHAIN+=("aresample=async=0:first_pts=0" "asetpts=N/SR/TB")
      ;;
    hard)
      AF_CHAIN+=("aresample=async=1:first_pts=0" "asetpts=N/SR/TB")
      ;;
    *)
      echo "ERROR: REBASING_MODE must be soft|hard|off" >&2
      exit 1
      ;;
  esac
fi

AF_OPT=()
if [[ ${#AF_CHAIN[@]} -gt 0 ]]; then
  AF_OPT=(-af "$(IFS=,; echo "${AF_CHAIN[*]}")")
fi

echo "  HPF:        ${HPF_ENABLE} (Hz=${HPF_HZ})"
echo "  TS_REBASE:  ${TS_REBASE} (mode=${REBASING_MODE})"
echo "  FORCE_AR:   ${FORCE_AR}"
echo "  FORCE_AC:   ${FORCE_AC}"
echo "  NOISERED:   ${NOISERED_ENABLE}"

# Coercion options (default enabled via FORCE_AR/FORCE_AC above)
AC_OPT=()
AR_OPT=()
if [[ -n "${FORCE_AC:-}" && "${FORCE_AC}" != "0" ]]; then AC_OPT=(-ac "$FORCE_AC"); fi
if [[ -n "${FORCE_AR:-}" && "${FORCE_AR}" != "0" ]]; then AR_OPT=(-ar "$FORCE_AR"); fi

workdir=$(mktemp -d)
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

full_wav="$workdir/full.wav"
sample_wav="$workdir/noise_sample.wav"
noise_prof="$workdir/noise.prof"
clean_wav="$workdir/clean.wav"

echo "Audio denoise (PCM)"
echo "  IN:        $IN"
echo "  OUT:       $OUT"
echo "  SS:        $SS"
echo "  T:         $T"
echo "  NR:        $NR"
echo "  NORM_DB:   $NORM_DB"
echo "  THREADS:   $THREADS"
echo

# 1) Extract full audio as 48 kHz stereo WAV for deterministic processing.
# Rebase audio timestamps to a monotonic sample clock to avoid DTS regressions.
"$FFMPEG_BIN" -hide_banner -nostdin -y \
  -fflags +genpts -i "$IN" \
  -vn -map 0:a:0 \
  "${AF_OPT[@]}" \
  "${AC_OPT[@]}" "${AR_OPT[@]}" \
  -c:a pcm_s16le \
  -threads "$THREADS" \
  "$full_wav"

# 2) Optional SoX noise profile + reduction
if [[ "$NOISERED_ENABLE" == "1" ]]; then
  "$FFMPEG_BIN" -hide_banner -nostdin -y \
    -fflags +genpts \
    -ss "$SS" -t "$T" \
    -i "$IN" \
    -vn -map 0:a:0 \
    "${AF_OPT[@]}" \
    "${AC_OPT[@]}" "${AR_OPT[@]}" \
    -c:a pcm_s16le \
    -threads "$THREADS" \
    "$sample_wav"
  "$SOX_BIN" "$sample_wav" -n noiseprof "$noise_prof"
  "$SOX_BIN" "$full_wav" "$clean_wav" noisered "$noise_prof" "$NR"
else
  # Pass-through (high-pass/rebase/48k already applied in ffmpeg extraction)
  cp -f "$full_wav" "$clean_wav"
fi

# 3) Optional normalization.
# sox norm takes a negative dB value, e.g. -1 => peak to -1 dBFS
norm_wav="$clean_wav"
case "${NORM_DB,,}" in
  ""|"off"|"none"|"0") ;;
  *)
    norm_wav="$workdir/norm.wav"
    "$SOX_BIN" "$clean_wav" "$norm_wav" norm "$NORM_DB"
    ;;
esac

# 4) Mux: copy video bit-exact, replace audio with denoised PCM.
"$FFMPEG_BIN" -hide_banner -nostdin -y \
  -fflags +genpts -i "$IN" \
  -fflags +genpts -i "$norm_wav" \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy \
  -c:a pcm_s16le \
  -avoid_negative_ts make_zero \
  -shortest \
  "$OUT"

echo
echo "Done. Output: $OUT"
