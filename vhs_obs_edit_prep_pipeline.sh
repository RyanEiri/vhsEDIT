#!/usr/bin/env bash
# vhs_obs_edit_prep_pipeline.sh
#
# OBS edit-prep pipeline (for the case where you captured via OBS instead of ffmpeg).
#
# What it does:
#   1) Select input MKV:
#        - If an argument is provided, that file is used.
#        - Otherwise, the newest date-stamped MKV in VIDEOS_DIR is used.
#   2) Stabilize using vhs_stabilize.sh (delegates to your proven denoise.sh)
#   3) Run QTGMC (idet-driven field order detection + env-driven qtgmc.vpy)
#   4) Write outputs to captures/stabilized/ (same location/pattern as vhs_edit_prep_pipeline.sh)
#   5) Print the Kdenlive command for the produced edit input, then exit.

set -euo pipefail

# ---- Configuration (override via environment) ----
VIDEOS_DIR="${VIDEOS_DIR:-$HOME/Videos}"
STABILIZE_SH="${STABILIZE_SH:-$VIDEOS_DIR/vhs_stabilize.sh}"

STABLE_DIR="${STABLE_DIR:-$VIDEOS_DIR/captures/stabilized}"
LOG_DIR="${LOG_DIR:-$VIDEOS_DIR/logs}"

# Stabilize tuning (passed through to vhs_stabilize.sh -> denoise.sh)
NOISE_SS="${NOISE_SS:-00:00:00}"
NOISE_T="${NOISE_T:-00:00:00.3}"
NR_AMOUNT="${NR_AMOUNT:-0.20}"
NORM_DB="${NORM_DB:--1}"
FFMPEG_THREADS="${FFMPEG_THREADS:-$(nproc)}"

# QTGMC config (mirrors vhs_edit_prep_pipeline.sh)
QTGMC_VPY="${QTGMC_VPY:-$VIDEOS_DIR/vhs-env/tools/qtgmc.vpy}"
VSPipe_BIN="${VSPipe_BIN:-$(command -v vspipe || true)}"
FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"

QTGMC_FORCE="${QTGMC_FORCE:-1}"     # 1 = run even if idet says progressive
QTGMC_FRAMES="${QTGMC_FRAMES:-600}" # idet sample frames
VS_PRESET="${VS_PRESET:-Slower}"
VS_FPSDIV="${VS_FPSDIV:-2}"         # 2 => 29.97p, 1 => 59.94p

usage() {
  cat <<'USAGE'
USAGE:
  vhs_obs_edit_prep_pipeline.sh [OBS_CAPTURE.mkv]

If no file is provided, the script picks the newest date-stamped MKV in $VIDEOS_DIR.

Outputs:
  captures/stabilized/<stem>_STABLE.mkv
  captures/stabilized/<stem>_STABLE_QTGMC.mkv (unless QTGMC is skipped)

Environment overrides:
  VIDEOS_DIR, STABILIZE_SH, STABLE_DIR, LOG_DIR
  NOISE_SS, NOISE_T, NR_AMOUNT, NORM_DB, FFMPEG_THREADS
  QTGMC_VPY, VSPipe_BIN, FFMPEG_BIN
  QTGMC_FORCE, QTGMC_FRAMES, VS_PRESET, VS_FPSDIV

Examples:
  vhs_obs_edit_prep_pipeline.sh "2026-01-09 23-29-04.mkv"
  NOISE_SS=00:00:05 NOISE_T=00:00:00.6 NR_AMOUNT=0.16 vhs_obs_edit_prep_pipeline.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$STABLE_DIR" "$LOG_DIR"

# ---- Preconditions ----
[[ -f "$STABILIZE_SH" ]] || { echo "ERROR: Missing required script: $STABILIZE_SH" >&2; exit 1; }
[[ -x "$STABILIZE_SH" ]] || { echo "ERROR: Not executable: $STABILIZE_SH (run chmod +x)" >&2; exit 1; }

[[ -f "$QTGMC_VPY" ]] || { echo "ERROR: QTGMC script not found: $QTGMC_VPY" >&2; exit 1; }
[[ -n "$VSPipe_BIN" && -x "$VSPipe_BIN" ]] || { echo "ERROR: vspipe not found in PATH (or not executable)" >&2; exit 1; }
[[ -x "$FFMPEG_BIN" ]] || { echo "ERROR: ffmpeg not found/executable: $FFMPEG_BIN" >&2; exit 1; }

# ---- 1) Select input MKV ----
input="${1:-}"

# Default: newest date-stamped MKV in VIDEOS_DIR (excluding pipeline outputs)
if [[ -z "$input" ]]; then
  input="$(
    find "$VIDEOS_DIR" -maxdepth 1 -type f -name '*.mkv' \
      ! -name '*_STABLE*.mkv' \
      ! -name '*_QTGMC*.mkv' \
      -printf '%T@ %p\n' \
    | sort -n \
    | awk '{print $2}' \
    | tail -n1
  )"
fi

if [[ -z "${input:-}" || ! -f "$input" ]]; then
  echo "ERROR: Could not determine input MKV." >&2
  echo "  VIDEOS_DIR: $VIDEOS_DIR" >&2
  echo "  Provided:  ${1:-<none>}" >&2
  exit 1
fi

# Normalize to absolute path for safety
if [[ "$input" != /* ]]; then
  input="$PWD/$input"
fi

base="$(basename "$input")"
stem="${base%.*}"

echo
echo "== OBS edit-prep pipeline =="
echo "Input:           $input"
echo "Stabilized dir:  $STABLE_DIR"
echo "Logs dir:        $LOG_DIR"
echo "Threads:         $FFMPEG_THREADS"
echo

# ---- 2) Stabilize ----
run_ts="$(date +%H-%M-%S)"
stable="$STABLE_DIR/${stem}_${run_ts}_STABLE.mkv"
stab_log="$LOG_DIR/${stem}_${run_ts}_stabilize.log"

echo "1) Stabilizing (delegating to denoise.sh via vhs_stabilize.sh)"
echo "   Output: $stable"

set +e
"$STABILIZE_SH" "$input" "$stable" "$NOISE_SS" "$NOISE_T" "$NR_AMOUNT" "$NORM_DB" "$FFMPEG_THREADS" 2>&1 | tee "$stab_log"
stab_rc="${PIPESTATUS[0]}"
set -e

if [[ "$stab_rc" -ne 0 ]]; then
  echo "ERROR: Stabilize step failed (exit $stab_rc). See: $stab_log" >&2
  exit "$stab_rc"
fi

echo
echo "Stabilized master: $stable"
echo "Stabilize log:     $stab_log"
echo

# ---- 3) QTGMC ----
echo "2) QTGMC (pre-edit deinterlace step)"

# idet to infer interlacing + field order
idet_log="$LOG_DIR/${stem}_${run_ts}_idet.log"
"$FFMPEG_BIN" -hide_banner -nostdin -i "$stable" -an \
  -vf idet -frames:v "$QTGMC_FRAMES" -f null - 2>&1 | tee "$idet_log" >/dev/null

read -r tff bff prog und <<<"$(
  awk '
    /Multi frame detection:/ {
      for (i=1;i<=NF;i++) {
        if ($i ~ /^TFF:/) tff=$(i+1)
        if ($i ~ /^BFF:/) bff=$(i+1)
        if ($i ~ /^Progressive:/) prog=$(i+1)
        if ($i ~ /^Undetermined:/) und=$(i+1)
      }
    }
    END { printf "%s %s %s %s\n", tff+0, bff+0, prog+0, und+0 }
  ' "$idet_log"
)"

interlaced=$((tff + bff))
run_qtgmc=0
if [[ "$QTGMC_FORCE" == "1" ]]; then
  run_qtgmc=1
elif [[ "$interlaced" -gt "$prog" ]]; then
  run_qtgmc=1
fi

VS_TFF="1"
if [[ "$bff" -gt "$tff" ]]; then
  VS_TFF="0"
fi

qtgmc_out="$STABLE_DIR/${stem}_${run_ts}_STABLE_QTGMC.mkv"

edit_input="$stable"

if [[ "$run_qtgmc" -eq 1 ]]; then
  echo "  idet: TFF=$tff BFF=$bff Progressive=$prog Undetermined=$und"
  echo "  -> Running QTGMC (VS_TFF=$VS_TFF, VS_FPSDIV=$VS_FPSDIV, VS_PRESET=$VS_PRESET)"
  echo "  Output: $qtgmc_out"

  export PYTHONPATH="$HOME/.local/share/vsrepo/py${PYTHONPATH:+:$PYTHONPATH}"
  export VS_INPUT="$stable"
  export VS_TFF="$VS_TFF"
  export VS_FPSDIV="$VS_FPSDIV"
  export VS_PRESET="$VS_PRESET"

  qtgmc_log="$LOG_DIR/${stem}_${run_ts}_qtgmc.log"
  set +e
  "$VSPipe_BIN" -c y4m "$QTGMC_VPY" - \
  | "$FFMPEG_BIN" -hide_banner -nostdin -y \
      -thread_queue_size 1024 -f yuv4mpegpipe -i - \
      -thread_queue_size 1024 -i "$stable" \
      -map 0:v:0 -map 1:a:0 \
      -c:v ffv1 -level 3 -pix_fmt yuv422p \
      -c:a copy \
      -shortest \
      "$qtgmc_out" 2>&1 | tee "$qtgmc_log"
  qtgmc_rc="${PIPESTATUS[1]}"
  set -e

  if [[ "$qtgmc_rc" -ne 0 ]]; then
    echo "ERROR: QTGMC step failed (exit $qtgmc_rc). See: $qtgmc_log" >&2
    exit "$qtgmc_rc"
  fi

  echo
  echo "QTGMC master: $qtgmc_out"
  echo "QTGMC log:    $qtgmc_log"
  echo

  edit_input="$qtgmc_out"
else
  echo "  idet: TFF=$tff BFF=$bff Progressive=$prog Undetermined=$und"
  echo "  -> Looks progressive; skipping QTGMC (set QTGMC_FORCE=1 to override)."
  echo
fi

echo "3) Next step: edit in Kdenlive"
echo
echo "Run:"
echo "  kdenlive \"${edit_input}\""
echo

exit 0
