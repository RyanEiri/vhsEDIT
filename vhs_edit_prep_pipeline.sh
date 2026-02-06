#!/usr/bin/env bash
# vhs_edit_prep_pipeline.sh
#
# Pipeline up to (but not including) Kdenlive editing:
#   1) Switch to archival mode
#   2) Capture archival master (FFV1/PCM) via vhs_capture_ffmpeg.sh
#      - IMPORTANT: Ctrl+C is treated as a NORMAL stop (exit 130), not a failure,
#        as long as an output file exists.
#   3) Stabilize by delegating to denoise.sh via vhs_stabilize.sh
#   4) Print the Kdenlive command to begin editing, then exit

set -euo pipefail

# ---- Configuration (override via environment) ----
VIDEOS_DIR="${VIDEOS_DIR:-$HOME/Videos}"

MODE_SH="${MODE_SH:-$VIDEOS_DIR/vhs_mode.sh}"
CAPTURE_SH="${CAPTURE_SH:-$VIDEOS_DIR/vhs_capture_ffmpeg.sh}"
STABILIZE_SH="${STABILIZE_SH:-$VIDEOS_DIR/vhs_stabilize.sh}"

ARCHIVAL_DIR="${ARCHIVAL_DIR:-$VIDEOS_DIR/captures/archival}"
STABLE_DIR="${STABLE_DIR:-$VIDEOS_DIR/captures/stabilized}"
LOG_DIR="${LOG_DIR:-$VIDEOS_DIR/logs}"

# Stabilize tuning (passed through to vhs_stabilize.sh -> denoise.sh)
NOISE_SS="${NOISE_SS:-00:00:00}"
NOISE_T="${NOISE_T:-00:00:00.3}"
NR_AMOUNT="${NR_AMOUNT:-0.20}"
NORM_DB="${NORM_DB:--1}"
FFMPEG_THREADS="${FFMPEG_THREADS:-$(nproc)}"

# Best-effort cleanup: set to 1 if you want to stop likely contenders first
KILL_AUDIO_HOGS="${KILL_AUDIO_HOGS:-0}"

usage() {
  cat <<'USAGE'
USAGE:
  vhs_edit_prep_pipeline.sh

What it does:
  - Sets mode: archival
  - Captures archival master (FFV1/PCM) using vhs_capture_ffmpeg.sh
    * Ctrl+C is a NORMAL stop. The pipeline continues if an output file exists.
  - Produces stabilized master using vhs_stabilize.sh (delegates to your proven denoise.sh)
  - Prints the Kdenlive command for the stabilized file and exits

Environment overrides:
  VIDEOS_DIR, MODE_SH, CAPTURE_SH, STABILIZE_SH
  ARCHIVAL_DIR, STABLE_DIR, LOG_DIR
  NOISE_SS, NOISE_T, NR_AMOUNT, NORM_DB, FFMPEG_THREADS
  KILL_AUDIO_HOGS=1 (attempt to stop processes holding capture audio)

Example:
  NOISE_SS=00:00:05 NOISE_T=00:00:00.6 NR_AMOUNT=0.16 vhs_edit_prep_pipeline.sh
USAGE
}

# ---- Preconditions ----
for f in "$MODE_SH" "$CAPTURE_SH" "$STABILIZE_SH"; do
  [[ -f "$f" ]] || { echo "ERROR: Missing required script: $f" >&2; exit 1; }
  [[ -x "$f" ]] || { echo "ERROR: Not executable: $f (run chmod +x)" >&2; exit 1; }
done

mkdir -p "$ARCHIVAL_DIR" "$STABLE_DIR" "$LOG_DIR"

if [[ "$KILL_AUDIO_HOGS" == "1" ]]; then
  pkill -x obs    2>/dev/null || true
  pkill -x ghb    2>/dev/null || true
  pkill -x ffmpeg 2>/dev/null || true
  pkill -x ffplay 2>/dev/null || true
fi

echo
echo "== VHS pipeline (to Kdenlive) =="
echo "Videos dir:      $VIDEOS_DIR"
echo "Archival dir:    $ARCHIVAL_DIR"
echo "Stabilized dir:  $STABLE_DIR"
echo "Threads:         $FFMPEG_THREADS"
echo

# ---- 1) Switch mode to archival ----
echo "1) Switching mode: archival"
"$MODE_SH" archival
echo

# ---- 2) Capture archival master ----
echo "2) Starting archival capture. Press Ctrl+C to stop cleanly."
echo "   (Ctrl+C is treated as a normal stop; the pipeline will continue.)"
echo

start_epoch="$(date +%s)"

cap_log="$LOG_DIR/VHS_CAPTURE_$(date +%F_%H-%M-%S).log"
set +e
"$CAPTURE_SH" 2>&1 | tee "$cap_log"
cap_rc="${PIPESTATUS[0]}"
set -e

# Attempt to parse output path from capture output log
captured="$(
  sed -nE 's/^(Output:|Out:)[[:space:]]+//p' "$cap_log" | tail -n1
)"

# Fallback: newest file created/modified after start time
if [[ -z "${captured:-}" ]]; then
  captured="$(
    find "$ARCHIVAL_DIR" -maxdepth 1 -type f -name '*.mkv' -printf '%T@ %p\n' \
    | awk -v s="$start_epoch" '$1 >= s {print $2}' \
    | tail -n1
  )"
fi

# Decide whether capture is acceptable:
# - rc=0 is success
# - rc=130 (Ctrl+C) is acceptable *if* we have a captured file on disk
if [[ "$cap_rc" -ne 0 ]]; then
  if [[ "$cap_rc" -eq 130 && -n "${captured:-}" && -f "$captured" ]]; then
    echo
    echo "Capture stopped by Ctrl+C (exit 130). Output file exists — continuing."
  else
    echo
    echo "ERROR: Capture step failed (exit $cap_rc). See: $cap_log" >&2
    exit "$cap_rc"
  fi
fi

if [[ -z "${captured:-}" || ! -f "$captured" ]]; then
  echo
  echo "ERROR: Could not determine captured file from log or directory scan." >&2
  echo "  Capture log: $cap_log" >&2
  echo "  Archival dir: $ARCHIVAL_DIR" >&2
  exit 1
fi

echo
echo "Captured archival master:"
echo "  $captured"
echo

# ---- 2b) Normalize capture filename to seg### (for segmented ingest) ----
#
# Produces: $ARCHIVAL_DIR/seg###.mkv (monotonic; never overwrites)
#
next_seg_id() {
  local max=0 n
  while IFS= read -r -d '' f; do
    n="$(basename "$f")"
    n="${n%.mkv}"
    n="${n#seg}"
    [[ "$n" =~ ^[0-9]{3}$ ]] || continue
    (( 10#$n > max )) && max=$((10#$n))
  done < <(find "$ARCHIVAL_DIR" -maxdepth 1 -type f -name 'seg[0-9][0-9][0-9].mkv' -print0 2>/dev/null || true)

  printf 'seg%03d' $((max + 1))
}

# If the capture script already emitted seg###.mkv, keep it. Otherwise rename.
cap_base="$(basename "$captured")"
if [[ ! "$cap_base" =~ ^seg[0-9]{3}\.mkv$ ]]; then
  seg_id="$(next_seg_id)"
  seg_path="$ARCHIVAL_DIR/${seg_id}.mkv"

  if [[ -e "$seg_path" ]]; then
    echo "ERROR: Refusing to overwrite existing segment: $seg_path" >&2
    exit 1
  fi

  echo "Renaming capture to segment ID: $seg_id"
  mv -- "$captured" "$seg_path"
  captured="$seg_path"
  echo "Segmented archival master:"
  echo "  $captured"
  echo
fi

# ---- 3) Stabilize (audio denoise via denoise.sh) ----
echo "3) Stabilizing (delegating to denoise.sh via vhs_stabilize.sh)"
base="$(basename "$captured")"
stem="${base%.*}"
stable="$STABLE_DIR/${stem}_STABLE.mkv"

stab_log="$LOG_DIR/${stem}_stabilize.log"
set +e
"$STABILIZE_SH" "$captured" "$stable" "$NOISE_SS" "$NOISE_T" "$NR_AMOUNT" "$NORM_DB" "$FFMPEG_THREADS" 2>&1 | tee "$stab_log"
stab_rc="${PIPESTATUS[0]}"
set -e

if [[ "$stab_rc" -ne 0 ]]; then
  echo
  echo "ERROR: Stabilize step failed (exit $stab_rc). See: $stab_log" >&2
  exit "$stab_rc"
fi

echo
echo "Stabilized master:"
echo "  $stable"
echo "Stabilize log:"
echo "  $stab_log"
echo

# ---- 4) QTGMC (optional but recommended before NLE) ----
echo "4) QTGMC (pre-edit deinterlace step)"

# Config (override via env)
QTGMC_VPY="${QTGMC_VPY:-$VIDEOS_DIR/vhs-env/tools/qtgmc.vpy}"
VSPipe_BIN="${VSPipe_BIN:-$(command -v vspipe || true)}"
FFMPEG_BIN="/usr/bin/ffmpeg"

QTGMC_FORCE="${QTGMC_FORCE:-1}"     # 1 = run even if idet says progressive
QTGMC_FRAMES="${QTGMC_FRAMES:-600}" # idet sample frames
VS_PRESET="${VS_PRESET:-Slower}"
VS_FPSDIV="${VS_FPSDIV:-2}"         # 2 => 29.97p, 1 => 59.94p

if [[ ! -f "$QTGMC_VPY" ]]; then
  echo "ERROR: QTGMC script not found: $QTGMC_VPY" >&2
  exit 1
fi
if [[ -z "$VSPipe_BIN" || ! -x "$VSPipe_BIN" ]]; then
  echo "ERROR: vspipe not found in PATH" >&2
  exit 1
fi
if [[ -z "$FFMPEG_BIN" || ! -x "$FFMPEG_BIN" ]]; then
  echo "ERROR: ffmpeg not found in PATH" >&2
  exit 1
fi

# Run idet to decide if QTGMC is needed (and infer field order)
idet_log="$LOG_DIR/${stem}_idet.log"
"$FFMPEG_BIN" -hide_banner -nostdin -i "$stable" -an \
  -vf idet -frames:v "$QTGMC_FRAMES" -f null - 2>&1 | tee "$idet_log" >/dev/null

# Extract counts from the *last* idet summary lines
# Prefer multi-frame detection as it is more stable.
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

# Decide interlaced vs progressive
interlaced=$((tff + bff))
run_qtgmc=0
if [[ "$QTGMC_FORCE" == "1" ]]; then
  run_qtgmc=1
elif [[ "$interlaced" -gt "$prog" ]]; then
  run_qtgmc=1
fi

# Pick field order based on which dominates
# VS_TFF expects 1 for TFF, 0 for BFF
VS_TFF="1"
if [[ "$bff" -gt "$tff" ]]; then
  VS_TFF="0"
fi

qtgmc_out="$STABLE_DIR/${stem}_STABLE_QTGMC.mkv"

if [[ "$run_qtgmc" -eq 1 ]]; then
  echo "  idet: TFF=$tff BFF=$bff Progressive=$prog Undetermined=$und"
  echo "  -> Running QTGMC (VS_TFF=$VS_TFF, VS_FPSDIV=$VS_FPSDIV, VS_PRESET=$VS_PRESET)"
  echo "  Output: $qtgmc_out"

  export PYTHONPATH="$HOME/.local/share/vsrepo/py${PYTHONPATH:+:$PYTHONPATH}"
  export VS_INPUT="$stable"
  export VS_TFF="$VS_TFF"
  export VS_FPSDIV="$VS_FPSDIV"
  export VS_PRESET="$VS_PRESET"

  qtgmc_log="$LOG_DIR/${stem}_qtgmc.log"
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

  echo "QTGMC master:"
  echo "  $qtgmc_out"
  echo "QTGMC log:"
  echo "  $qtgmc_log"
  echo

  edit_input="$qtgmc_out"
else
  echo "  idet: TFF=$tff BFF=$bff Progressive=$prog Undetermined=$und"
  echo "  -> Looks progressive; skipping QTGMC (set QTGMC_FORCE=1 to override)."
  echo
  edit_input="$stable"
fi

echo "5) Next step: edit in Kdenlive"
echo
echo "Run:"
echo "  kdenlive \"${edit_input}\""
echo

exit 0
