#!/usr/bin/env bash
#
# vhs_upscale.sh
#
# Chunked, resumable VHS upscaling using Real-ESRGAN (realesrgan-ncnn-vulkan).
#
# Per-segment pipeline:
#   1) Extract JPEG frames for the segment (from input; video only)
#   2) Upscale frames with Real-ESRGAN (Vulkan) at INTERNAL_SCALE
#   3) Rebuild the segment video by downscaling to FINAL_SCALE and encoding H.264
#   4) Save the encoded segment as a resume checkpoint: segments/seg_XXX.mp4
#
# After all segments:
#   5) Concatenate segments (video-only)
#   6) Remux original audio from the input into the final output
#
# Work directory layout (per input basename):
#   WORK_ROOT/<input-stem>/
#     segments/seg_XXX.mp4   (resume checkpoints)
#     frames/                (temporary per-segment)
#     frames_up/             (temporary per-segment)
#     segments.txt           (concat list)
#     video_concat.mp4       (video-only concatenation)
#     run_config.txt         (effective configuration used for generated segments)
#
# Resumability:
#   - If segments/seg_XXX.mp4 exists and is non-empty, that segment is skipped.
#   - Resume granularity is per segment (not within a segment).
#
# Safety guard:
#   - A configuration fingerprint is written to run_config.txt.
#   - If segments exist and the fingerprint differs, the script stops to prevent
#     mixed settings output unless ALLOW_MIXED=1.
#
# Usage:
#   ./vhs_upscale.sh INPUT OUTPUT [segment_seconds] [crf]
#
# Defaults:
#   segment_seconds = 30
#   crf             = 21
#
# Environment variables (optional):
#   WORK_ROOT        Workdir root (default: "$PWD/vhs_upscale_work")
#   MODELS_DIR       Real-ESRGAN models dir (default: "$HOME/opt/realesrgan-ncnn/models")
#   MODEL            Model name (default: realesrgan-x4plus)
#   INTERNAL_SCALE   Internal scale factor (default: 4)
#   FINAL_SCALE      Final scale relative to input (default: 2)
#   TILE_SIZE        Real-ESRGAN tile size (default: 400)
#   THREADS          Real-ESRGAN threads string (default: 3:3:2)
#   VK_DEVICE_INDEX  Vulkan device index for Real-ESRGAN (default: 0)
#   JPEG_QUALITY     ffmpeg qscale for JPEG extraction (default: 2)
#   PRESET           x264 preset (default: veryfast)
#   PRE_VF           ffmpeg -vf filter chain applied during frame extraction, before
#                    Real-ESRGAN sees the frames. Denoises shadow noise and crushes
#                    blacks so the upscaler doesn't hallucinate texture in dark areas.
#                    Default: hqdn3d=3:2:4:3,curves=all='0/0 0.05/0 1/1'
#                    Override with PRE_VF="" to disable.
#   ALLOW_MIXED      Set to 1 to allow reuse of segments even if config changed
#
# Requirements:
#   - ffmpeg, ffprobe
#   - realesrgan-ncnn-vulkan in PATH

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 INPUT OUTPUT [segment_seconds] [crf]" >&2
  exit 1
fi

IN="$1"
OUT="$2"
SEG_SECONDS="${3:-30}"
CRF="${4:-21}"

# ---- knobs ----
WORK_ROOT="${WORK_ROOT:-$PWD/vhs_upscale_work}"
MODELS_DIR="${MODELS_DIR:-$HOME/opt/realesrgan-ncnn/models}"
MODEL="${MODEL:-realesrgan-x4plus}"
INTERNAL_SCALE="${INTERNAL_SCALE:-4}"
FINAL_SCALE="${FINAL_SCALE:-2}"
TILE_SIZE="${TILE_SIZE:-400}"
THREADS="${THREADS:-3:3:2}"
VK_DEVICE_INDEX="${VK_DEVICE_INDEX:-0}"
JPEG_QUALITY="${JPEG_QUALITY:-2}"
PRESET="${PRESET:-veryfast}"
PRE_VF="${PRE_VF:-hqdn3d=3:2:4:3,curves=all='0/0 0.05/0 1/1'}"
ALLOW_MIXED="${ALLOW_MIXED:-0}"

FRAME_EXT="jpg"

FFMPEG="/usr/bin/ffmpeg"
FFPROBE="/usr/bin/ffprobe"

# ---- dependency checks ----
[ -x "$FFMPEG" ]  || { echo "Error: $FFMPEG not found or not executable."; exit 1; }
[ -x "$FFPROBE" ] || { echo "Error: $FFPROBE not found or not executable."; exit 1; }
command -v realesrgan-ncnn-vulkan >/dev/null 2>&1 || { echo "Error: realesrgan-ncnn-vulkan not found in PATH."; exit 1; }

[ -f "$IN" ] || { echo "Error: input file '$IN' not found." >&2; exit 1; }
[ -d "$MODELS_DIR" ] || { echo "Error: MODELS_DIR '$MODELS_DIR' not found." >&2; exit 1; }

BASE_NAME="$(basename "$IN")"
BASE_STEM="${BASE_NAME%.*}"

WORK_DIR="$WORK_ROOT/$BASE_STEM"
segments_dir="$WORK_DIR/segments"
frames_dir="$WORK_DIR/frames"
upscaled_dir="$WORK_DIR/frames_up"

mkdir -p "$segments_dir" "$frames_dir" "$upscaled_dir"

# ---- probe input ----
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

# ---- validate scale math ----
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
DOWNSCALE_DIV=$(( INTERNAL_SCALE / FINAL_SCALE ))

# Compute DAR-correct output dimensions.
# NTSC 720x480 has non-square pixels (SAR ~8:9) but most VHS captures don't carry
# correct SAR metadata, so ffprobe reports DAR as 3:2 instead of the true 4:3.
# TARGET_DAR overrides the probed DAR; default 4:3 for this VHS pipeline.
# Set TARGET_DAR="" to fall back to simple pixel scaling.
TARGET_DAR="${TARGET_DAR:-4:3}"
FINAL_H=$(( src_h * FINAL_SCALE ))
if [[ -n "$TARGET_DAR" && "$TARGET_DAR" == *:* ]]; then
  dar_num="${TARGET_DAR%%:*}"
  dar_den="${TARGET_DAR##*:}"
  FINAL_W=$(( FINAL_H * dar_num / dar_den ))
  # Ensure even width (H.264 requirement)
  FINAL_W=$(( FINAL_W + (FINAL_W % 2) ))
else
  FINAL_W=$(( src_w * FINAL_SCALE ))
fi

# ---- safer resume guard ----
CONFIG_FILE="$WORK_DIR/run_config.txt"
CONFIG_PAYLOAD=$(cat <<CFG
SCRIPT=vhs_upscale.sh
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
PRESET=$PRESET
PRE_VF=$PRE_VF
CFG
)

shopt -s nullglob
existing_segments=("$segments_dir"/seg_*.mp4)
shopt -u nullglob

if [ -f "$CONFIG_FILE" ] && [ "${#existing_segments[@]}" -gt 0 ] && [ "$ALLOW_MIXED" != "1" ]; then
  if ! diff -q <(printf '%s' "$CONFIG_PAYLOAD") "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "Error: existing segments found, but current configuration differs from the" >&2
    echo "       configuration used to generate them." >&2
    echo >&2
    echo "Work dir : $WORK_DIR" >&2
    echo "Config   : $CONFIG_FILE" >&2
    echo >&2
    echo "To proceed safely:" >&2
    echo "  rm -f '$segments_dir'/seg_*.mp4" >&2
    echo "or" >&2
    echo "  rm -rf '$WORK_DIR'" >&2
    echo "or override (NOT recommended):" >&2
    echo "  ALLOW_MIXED=1 $0 ..." >&2
    echo >&2
    echo "Current effective configuration:" >&2
    echo "$CONFIG_PAYLOAD" >&2
    exit 1
  fi
fi

printf '%s' "$CONFIG_PAYLOAD" > "$CONFIG_FILE"

echo ">>> VHS upscale (chunked, resumable)"
echo "Input file      : $IN"
echo "Output file     : $OUT"
echo "Chunk length    : ${SEG_SECONDS}s"
echo "CRF             : ${CRF}"
echo "x264 preset     : ${PRESET}"
echo "Model           : $MODEL (internal ${INTERNAL_SCALE}x, final ${FINAL_SCALE}x)"
echo "Models dir      : $MODELS_DIR"
echo "JPEG quality    : qscale=$JPEG_QUALITY"
echo "Tile size       : $TILE_SIZE"
echo "Threads         : $THREADS"
echo "Vulkan device   : $VK_DEVICE_INDEX"
echo "Work dir        : $WORK_DIR"
echo "Config file     : $CONFIG_FILE"
echo "Duration        : ~${TOTAL_SECONDS}s"
echo "FPS             : ${fps}"
echo "Source          : ${src_w}x${src_h} (TARGET_DAR ${TARGET_DAR:-none})"
echo "Output          : ${FINAL_W}x${FINAL_H}"
[[ -n "$PRE_VF" ]] && echo "Pre-filter      : $PRE_VF"
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

  echo "  -> Extracting frames (video only)..."
  pre_vf_args=()
  [[ -n "$PRE_VF" ]] && pre_vf_args=(-vf "$PRE_VF")
  "$FFMPEG" -y \
    -ss "$start" \
    -t "$seg_len" \
    -i "$IN" \
    -an \
    "${pre_vf_args[@]}" \
    -qscale:v "$JPEG_QUALITY" \
    "$frames_dir/frame_%08d.$FRAME_EXT"

  if ! ls "$frames_dir"/*."$FRAME_EXT" >/dev/null 2>&1; then
    echo "  -> No frames extracted for this segment; stopping." >&2
    break
  fi

  echo "  -> Real-ESRGAN upscaling..."
  realesrgan-ncnn-vulkan \
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
  # IMPORTANT: -preset is an encoder/output option; it must come AFTER inputs.
  "$FFMPEG" -y \
    -framerate "$fps" \
    -i "$upscaled_dir/frame_%08d.$FRAME_EXT" \
    -vf "scale=${FINAL_W}:${FINAL_H}:flags=lanczos,setsar=1" \
    -an \
    -c:v libx264 \
    -preset "$PRESET" \
    -crf "$CRF" \
    -pix_fmt yuv420p \
    "$seg_out"

  rm -rf "$frames_dir" "$upscaled_dir"
  echo

done

# ---- concatenate segments ----
shopt -s nullglob
segment_files=("$segments_dir"/seg_*.mp4)
shopt -u nullglob

if [ "${#segment_files[@]}" -eq 0 ]; then
  echo "Error: no segment files found in $segments_dir." >&2
  exit 1
fi

IFS=$'\n' segment_files_sorted=( $(printf '%s\n' "${segment_files[@]}" | sort) )
unset IFS

concat_list="$WORK_DIR/segments.txt"
: > "$concat_list"
for f in "${segment_files_sorted[@]}"; do
  echo "file '$f'" >> "$concat_list"
done

concat_video="$WORK_DIR/video_concat.mp4"

echo ">>> Concatenating ${#segment_files_sorted[@]} segment(s) into: $concat_video"
"$FFMPEG" -y \
  -f concat -safe 0 \
  -i "$concat_list" \
  -c copy \
  "$concat_video"

echo ">>> Muxing original audio into final upscaled video: $OUT"
# Map first audio stream if present; if none, just copy video out.
if "$FFPROBE" -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$IN" >/dev/null 2>&1; then
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

echo
echo "All done."
echo "Final upscaled file: $OUT"
echo "Work dir (resume/inspection): $WORK_DIR"
