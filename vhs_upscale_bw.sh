#!/usr/bin/env bash
#
# vhs_upscale_bw.sh
#
# Black-and-white wrapper for vhs_upscale.sh logic:
# - Identical chunking/resume behavior
# - Extract frames as grayscale (but stored as RGB JPG for Real-ESRGAN compatibility)
# - Rebuild segments and final output with neutral chroma
#
# Usage:
#   ./vhs_upscale_bw.sh INPUT OUTPUT [segment_seconds] [crf]
#
# Environment variables:
#   Same as vhs_upscale.sh, plus:
#     CRUSH       Crush preset: none (default), small, medium, heavy — same as vhs_upscale.sh
#                 but all presets include hue=s=0 for grayscale
#     BRIGHTNESS  Override the preset's default brightness (e.g. BRIGHTNESS=0.08)
#     BW_FILTER   Explicit filter chain — overrides CRUSH if set
#
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 INPUT OUTPUT [segment_seconds] [crf]" >&2
  exit 1
fi

IN="$1"
OUT="$2"
SEG_SECONDS="${3:-30}"
CRF="${4:-21}"

WORK_ROOT="${WORK_ROOT:-/media/ryan/Patriot/Videos/vhs_upscale_work}"
MODELS_DIR="${MODELS_DIR:-$HOME/opt/realesrgan-ncnn/models}"
MODEL="${MODEL:-realesrgan-x4plus}"
INTERNAL_SCALE="${INTERNAL_SCALE:-4}"
FINAL_SCALE="${FINAL_SCALE:-2}"
ALLOW_MIXED="${ALLOW_MIXED:-0}"
UPSCALE_BACKEND="${UPSCALE_BACKEND:-vulkan}"
case "$UPSCALE_BACKEND" in
  vulkan) UPSCALE_BIN="realesrgan-ncnn-vulkan"; _tile_default=400 ;;
  rocm)   UPSCALE_BIN="realesrgan-rocm";         _tile_default=0   ;;
  *) echo "Unknown UPSCALE_BACKEND=$UPSCALE_BACKEND (expected: vulkan|rocm)" >&2; exit 2 ;;
esac
# realesrgan-ncnn-vulkan hardcodes its network architecture by matching -n
# against these families; any other name segfaults it instead of erroring.
if [ "$UPSCALE_BACKEND" = "vulkan" ]; then
  case "$MODEL" in
    realesrgan-x4plus|realesrgan-x4plus-anime|realesrnet-x4plus|realesr-animevideov3*) ;;
    *) echo "Error: MODEL='$MODEL' is not supported by the vulkan backend (realesrgan-ncnn-vulkan crashes on unrecognized model names). Use UPSCALE_BACKEND=rocm for community VHS models (2x_VHS-Film, ToonVHS-1x, VHS-Sharpen-1x)." >&2; exit 2 ;;
  esac
fi
TILE_SIZE="${TILE_SIZE:-$_tile_default}"
THREADS="${THREADS:-3:3:3}"
VK_DEVICE_INDEX="${VK_DEVICE_INDEX:-0}"
JPEG_QUALITY="${JPEG_QUALITY:-2}"
PRESET="${PRESET:-veryfast}"

# ---- crush presets (CRUSH=none|small|medium|heavy, default: none) ----
# Explicit BW_FILTER overrides CRUSH. BRIGHTNESS overrides the preset's default brightness.
# All presets include hue=s=0 for grayscale.
_resolve_brightness() {
  case "$1" in
    none)   echo "0" ;;
    low)    echo "0.02" ;;
    medium) echo "0.05" ;;
    high)   echo "0.095" ;;
    *)      echo "$1" ;;
  esac
}

if [ -z "${BW_FILTER+x}" ]; then
  case "${CRUSH:-none}" in
    none)   _crush="hqdn3d=3:2:4:3,hue=s=0"                                                        ; _bright="$(_resolve_brightness "${BRIGHTNESS:-0}")" ;;
    small)  _crush="hqdn3d=3:2:4:3,hue=s=0,lutyuv=y='if(lt(val,16),0,min(255,(val-16)*255/239))'" ; _bright="$(_resolve_brightness "${BRIGHTNESS:-0}")" ;;
    medium) _crush="hqdn3d=3:2:4:3,hue=s=0,lutyuv=y='if(lt(val,50),0,min(255,(val-50)*255/205))'" ; _bright="$(_resolve_brightness "${BRIGHTNESS:-0.05}")" ;;
    heavy)  _crush="hqdn3d=3:2:4:3,hue=s=0,lutyuv=y='if(lt(val,70),0,min(255,(val-70)*255/185))'" ; _bright="$(_resolve_brightness "${BRIGHTNESS:-0.095}")" ;;
    *)      echo "ERROR: Unknown CRUSH preset '${CRUSH}' (expected: none|small|medium|heavy)" >&2; exit 1 ;;
  esac
  if [ "$_bright" != "0" ]; then
    BW_FILTER="${_crush},eq=brightness=${_bright}"
  else
    BW_FILTER="$_crush"
  fi
fi

FRAME_EXT="jpg"

FFMPEG="/usr/bin/ffmpeg"
FFPROBE="/usr/bin/ffprobe"

[ -x "$FFMPEG" ]  || { echo "Error: $FFMPEG not found or not executable."; exit 1; }
[ -x "$FFPROBE" ] || { echo "Error: $FFPROBE not found or not executable."; exit 1; }
command -v "$UPSCALE_BIN" >/dev/null 2>&1 || { echo "Error: $UPSCALE_BIN not found in PATH."; exit 1; }

[ -f "$IN" ] || { echo "Error: input file '$IN' not found." >&2; exit 1; }
[ -d "$MODELS_DIR" ] || { echo "Error: MODELS_DIR '$MODELS_DIR' not found." >&2; exit 1; }

BASE_NAME="$(basename "$IN")"
BASE_STEM="${BASE_NAME%.*}"

WORK_DIR="$WORK_ROOT/$BASE_STEM"
segments_dir="$WORK_DIR/segments"
frames_dir="$WORK_DIR/frames"
upscaled_dir="$WORK_DIR/frames_up"

mkdir -p "$segments_dir" "$frames_dir" "$upscaled_dir"

# Write PGID so the process group can be paused/resumed with kill
_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
echo "$_pgid" > "$WORK_DIR/upscale.pgid"
trap 'rm -f "$WORK_DIR/upscale.pgid"' EXIT

duration="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$IN" || true)"
if [ -z "${duration:-}" ]; then
  echo "Error: could not determine input duration." >&2
  exit 1
fi
TOTAL_SECONDS="$(awk -v d="$duration" 'BEGIN{print (d==int(d)?int(d):int(d)+1)}')"

fps="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$IN" || true)"
if [ -z "${fps:-}" ]; then
  echo "Warning: could not determine r_frame_rate; defaulting to 30000/1001" >&2
  fps="30000/1001"
fi

# Probe source dimensions for DAR-correct output
src_w="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$IN")"
src_h="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$IN")"

if ! [[ "$INTERNAL_SCALE" =~ ^[0-9]+$ ]] || ! [[ "$FINAL_SCALE" =~ ^[0-9]+$ ]]; then
  echo "Error: INTERNAL_SCALE and FINAL_SCALE must be integers." >&2
  exit 1
fi
if [ "$FINAL_SCALE" -le 0 ] || [ "$INTERNAL_SCALE" -le 0 ]; then
  echo "Error: INTERNAL_SCALE and FINAL_SCALE must be positive." >&2
  exit 1
fi
if [ $(( INTERNAL_SCALE % FINAL_SCALE )) -ne 0 ]; then
  echo "Error: INTERNAL_SCALE must be evenly divisible by FINAL_SCALE (got $INTERNAL_SCALE and $FINAL_SCALE)." >&2
  exit 1
fi

# Compute DAR-correct output dimensions.
TARGET_DAR="${TARGET_DAR:-4:3}"
FINAL_H=$(( src_h * FINAL_SCALE ))
if [[ -n "$TARGET_DAR" && "$TARGET_DAR" == *:* ]]; then
  dar_num="${TARGET_DAR%%:*}"
  dar_den="${TARGET_DAR##*:}"
  FINAL_W=$(( FINAL_H * dar_num / dar_den ))
  FINAL_W=$(( FINAL_W + (FINAL_W % 2) ))
else
  FINAL_W=$(( src_w * FINAL_SCALE ))
fi

CONFIG_FILE="$WORK_DIR/run_config.txt"
CONFIG_PAYLOAD=$(cat <<CFG
SCRIPT=vhs_upscale_bw.sh
INPUT_BASENAME=$BASE_NAME
SEG_SECONDS=$SEG_SECONDS
CRF=$CRF
FPS=$fps
MODEL=$MODEL
MODELS_DIR=$MODELS_DIR
INTERNAL_SCALE=$INTERNAL_SCALE
FINAL_SCALE=$FINAL_SCALE
JPEG_QUALITY=$JPEG_QUALITY
TILE_SIZE=$TILE_SIZE
THREADS=$THREADS
VK_DEVICE_INDEX=$VK_DEVICE_INDEX
UPSCALE_BACKEND=$UPSCALE_BACKEND
PRESET=$PRESET
BW_FILTER=$BW_FILTER
CFG
)

shopt -s nullglob
existing_segments=("$segments_dir"/seg_*.mp4)
shopt -u nullglob

if [ -f "$CONFIG_FILE" ] && [ "${#existing_segments[@]}" -gt 0 ] && [ "$ALLOW_MIXED" != "1" ]; then
  if ! diff -q <(printf '%s' "$CONFIG_PAYLOAD") "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "Error: existing segments found, but current configuration differs." >&2
    echo "Work dir : $WORK_DIR" >&2
    echo "Config   : $CONFIG_FILE" >&2
    echo "To proceed safely, remove segments or the work dir, or set ALLOW_MIXED=1." >&2
    exit 1
  fi
fi

printf '%s' "$CONFIG_PAYLOAD" > "$CONFIG_FILE"

echo ">>> VHS B&W upscale (chunked, resumable)"
echo "Input file      : $IN"
echo "Output file     : $OUT"
echo "Chunk length    : ${SEG_SECONDS}s"
echo "CRF             : ${CRF}"
echo "x264 preset     : ${PRESET}"
echo "Model           : $MODEL (internal ${INTERNAL_SCALE}x, final ${FINAL_SCALE}x)"
echo "BW filter       : $BW_FILTER"
echo "Work dir        : $WORK_DIR"
echo "Duration        : ~${TOTAL_SECONDS}s"
echo "FPS             : ${fps}"
echo "Source          : ${src_w}x${src_h} (TARGET_DAR ${TARGET_DAR:-none})"
echo "Output          : ${FINAL_W}x${FINAL_H}"
echo

SEG_COUNT=$(( (TOTAL_SECONDS + SEG_SECONDS - 1) / SEG_SECONDS ))

for ((i=0; i<SEG_COUNT; i++)); do
  start=$(( i * SEG_SECONDS ))
  seg_len=$SEG_SECONDS
  if [ $(( start + seg_len )) -gt "$TOTAL_SECONDS" ]; then
    seg_len=$(( TOTAL_SECONDS - start ))
  fi

  seg_out="$segments_dir/seg_$(printf '%03d' "$i").mp4"

  if [ -s "$seg_out" ]; then
    echo "[seg $(printf '%03d' "$i")] exists - skipping ($seg_out)"
    continue
  fi

  echo "[seg $(printf '%03d' "$i")] start=${start}s len=${seg_len}s"

  rm -rf "$frames_dir" "$upscaled_dir"
  mkdir -p "$frames_dir" "$upscaled_dir"

  echo "  -> Extracting grayscale frames (stored as RGB JPG for compatibility)..."
  "$FFMPEG" -y \
    -ss "$start" \
    -t "$seg_len" \
    -i "$IN" \
    -an \
    -vf "${BW_FILTER},format=rgb24" \
    -qscale:v "$JPEG_QUALITY" \
    "$frames_dir/frame_%08d.$FRAME_EXT"

  if ! ls "$frames_dir"/*."$FRAME_EXT" >/dev/null 2>&1; then
    echo "  -> No frames extracted for this segment; stopping." >&2
    break
  fi

  echo "  -> Real-ESRGAN upscaling..."
  "$UPSCALE_BIN" \
    -i "$frames_dir" \
    -o "$upscaled_dir" \
    -s "$INTERNAL_SCALE" \
    -m "$MODELS_DIR" \
    -n "$MODEL" \
    -t "$TILE_SIZE" \
    -j "$THREADS" \
    -g "$VK_DEVICE_INDEX" \
    -f jpg

  echo "  -> Rebuilding segment video at ${FINAL_W}x${FINAL_H} (DAR-correct)..."
  "$FFMPEG" -y \
    -framerate "$fps" \
    -i "$upscaled_dir/frame_%08d.$FRAME_EXT" \
    -vf "scale=${FINAL_W}:${FINAL_H}:flags=lanczos,setsar=1,format=yuv420p" \
    -an \
    -c:v libx264 \
    -preset "$PRESET" \
    -crf "$CRF" \
    -pix_fmt yuv420p \
    "$seg_out"

  rm -rf "$frames_dir" "$upscaled_dir"
  echo
done

# ---- validate segments before assembly (auto-repair once) ----
_validate_segments() {
  echo ">>> Validating segments..."
  shopt -s nullglob
  segment_files=("$segments_dir"/seg_*.mp4)
  shopt -u nullglob

  if [ "${#segment_files[@]}" -eq 0 ]; then
    echo "Error: no segment files found in $segments_dir." >&2
    return 2
  fi

  mapfile -t segment_files_sorted < <(printf '%s\n' "${segment_files[@]}" | sort)

  bad_segments=()
  total_seg_duration=0
  min_seg_duration=$(( SEG_SECONDS / 3 ))

  for f in "${segment_files_sorted[@]}"; do
    seg_dur="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null || true)"
    seg_name="$(basename "$f")"

    if [ -z "${seg_dur:-}" ]; then
      echo "  CORRUPT: $seg_name — ffprobe could not read file" >&2
      bad_segments+=("$f")
      continue
    fi

    seg_dur_int="${seg_dur%%.*}"
    total_seg_duration="$(awk -v t="$total_seg_duration" -v d="$seg_dur" 'BEGIN{printf "%.3f", t+d}')"

    # Flag segments that are suspiciously short (but not the last segment)
    if [ "$seg_name" != "$(basename "${segment_files_sorted[-1]}")" ] && [ "${seg_dur_int:-0}" -lt "$min_seg_duration" ]; then
      echo "  SHORT:   $seg_name — ${seg_dur}s (expected ~${SEG_SECONDS}s)" >&2
      bad_segments+=("$f")
    fi
  done

  # Check total video duration against source
  source_dur="$duration"
  drift="$(awk -v v="$total_seg_duration" -v s="$source_dur" 'BEGIN{d=s-v; printf "%.1f", (d<0?-d:d)}')"
  drift_pct="$(awk -v v="$total_seg_duration" -v s="$source_dur" 'BEGIN{printf "%.1f", ((s-v)/s)*100}')"

  echo "  Segment count   : ${#segment_files_sorted[@]}"
  echo "  Total video dur : ${total_seg_duration}s"
  echo "  Source duration  : ${source_dur}s"
  echo "  Drift            : ${drift}s (${drift_pct}%)"

  if [ "${#bad_segments[@]}" -gt 0 ]; then
    return 1
  fi

  max_drift_pct=2
  if awk -v d="$drift_pct" -v m="$max_drift_pct" 'BEGIN{exit !(d > m)}'; then
    echo "  WARNING: total segment duration drifts ${drift_pct}% from source (${drift}s)." >&2
    return 1
  fi

  echo "  Validation passed."
  echo
  return 0
}

if ! _validate_segments; then
  if [ "${#bad_segments[@]}" -gt 0 ]; then
    echo
    echo ">>> Auto-repair: removing ${#bad_segments[@]} bad segment(s) and regenerating..."
    for f in "${bad_segments[@]}"; do
      echo "  rm $(basename "$f")"
      rm -f "$f"
    done
    echo
  else
    echo ">>> Auto-repair: duration drift detected, re-running segment loop..."
    echo
  fi

  # Re-run the segment processing loop (skips existing good segments)
  for ((i=0; i<SEG_COUNT; i++)); do
    start=$(( i * SEG_SECONDS ))
    seg_len=$SEG_SECONDS
    if [ $(( start + seg_len )) -gt "$TOTAL_SECONDS" ]; then
      seg_len=$(( TOTAL_SECONDS - start ))
    fi

    seg_out="$segments_dir/seg_$(printf '%03d' "$i").mp4"

    if [ -s "$seg_out" ]; then
      continue
    fi

    echo "[seg $(printf '%03d' "$i")] REPAIR: start=${start}s len=${seg_len}s"

    rm -rf "$frames_dir" "$upscaled_dir"
    mkdir -p "$frames_dir" "$upscaled_dir"

    echo "  -> Extracting grayscale frames (stored as RGB JPG for compatibility)..."
    "$FFMPEG" -y \
      -ss "$start" \
      -t "$seg_len" \
      -i "$IN" \
      -an \
      -vf "${BW_FILTER},format=rgb24" \
      -qscale:v "$JPEG_QUALITY" \
      "$frames_dir/frame_%08d.$FRAME_EXT"

    if ! ls "$frames_dir"/*."$FRAME_EXT" >/dev/null 2>&1; then
      echo "  -> No frames extracted for this segment; stopping." >&2
      break
    fi

    echo "  -> Real-ESRGAN upscaling..."
    "$UPSCALE_BIN" \
      -i "$frames_dir" \
      -o "$upscaled_dir" \
      -s "$INTERNAL_SCALE" \
      -m "$MODELS_DIR" \
      -n "$MODEL" \
      -t "$TILE_SIZE" \
      -j "$THREADS" \
      -g "$VK_DEVICE_INDEX" \
      -f jpg

    echo "  -> Rebuilding segment video at ${FINAL_W}x${FINAL_H} (DAR-correct)..."
    "$FFMPEG" -y \
      -framerate "$fps" \
      -i "$upscaled_dir/frame_%08d.$FRAME_EXT" \
      -vf "scale=${FINAL_W}:${FINAL_H}:flags=lanczos,setsar=1,format=yuv420p" \
      -an \
      -c:v libx264 \
      -preset "$PRESET" \
      -crf "$CRF" \
      -pix_fmt yuv420p \
      "$seg_out"

    rm -rf "$frames_dir" "$upscaled_dir"
    echo
  done

  # Validate again — if still bad, abort
  if ! _validate_segments; then
    echo "Error: segments still invalid after auto-repair. Aborting." >&2
    echo "Inspect: $segments_dir" >&2
    exit 1
  fi
fi

concat_list="$WORK_DIR/segments.txt"
: > "$concat_list"
for f in "${segment_files_sorted[@]}"; do
  echo "file 'segments/$(basename "$f")'" >> "$concat_list"
done

concat_video="$WORK_DIR/video_concat.mp4"

echo ">>> Concatenating ${#segment_files_sorted[@]} segment(s) into: $concat_video"
"$FFMPEG" -y \
  -f concat -safe 0 \
  -i "$concat_list" \
  -c copy \
  "$concat_video"

echo ">>> Muxing original audio into final upscaled video: $OUT"
if [[ -n "$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null)" ]]; then
  "$FFMPEG" -y \
    -i "$concat_video" \
    -i "$IN" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy \
    -c:a aac -b:a 160k \
    "$OUT"
else
  echo "Warning: no audio stream detected in input; writing video-only output." >&2
  "$FFMPEG" -y \
    -i "$concat_video" \
    -c copy \
    "$OUT"
fi

# Fix A/V sync drift that can accumulate through segment encode + concat.
_sync_fix="$(dirname "$0")/vhs_fix_sync.sh"
if [[ -x "$_sync_fix" ]] && \
   [[ -n "$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null)" ]]; then
  _sync_tmp="${OUT%.mkv}._synctmp.mkv"
  echo ">>> Checking A/V sync drift in output..."
  if "$_sync_fix" "$OUT" "$_sync_tmp"; then
    if [[ -f "$_sync_tmp" ]]; then
      mv "$_sync_tmp" "$OUT"
      echo "    Output replaced with sync-corrected version."
    fi
  else
    echo "Warning: sync fix failed; keeping original output." >&2
  fi
  rm -f "$_sync_tmp"
fi

echo
echo "All done."
echo "Final B&W upscaled file: $OUT"
echo "Work dir (resume/inspection): $WORK_DIR"
