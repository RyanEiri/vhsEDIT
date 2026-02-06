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
#     BW_FILTER   ffmpeg filter to force grayscale during frame extraction (default: hue=s=0)
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
ALLOW_MIXED="${ALLOW_MIXED:-0}"

BW_FILTER="${BW_FILTER:-hue=s=0}"

FRAME_EXT="jpg"

FFMPEG="/usr/bin/ffmpeg"
FFPROBE="/usr/bin/ffprobe"

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

  echo "  -> Rebuilding segment video at ${FINAL_SCALE}x resolution..."
  "$FFMPEG" -y \
    -framerate "$fps" \
    -i "$upscaled_dir/frame_%08d.$FRAME_EXT" \
    -vf "scale=iw/${DOWNSCALE_DIV}:ih/${DOWNSCALE_DIV}:flags=lanczos,setsar=1,format=yuv420p" \
    -an \
    -c:v libx264 \
    -preset "$PRESET" \
    -crf "$CRF" \
    -pix_fmt yuv420p \
    "$seg_out"

  rm -rf "$frames_dir" "$upscaled_dir"
  echo
done

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
echo "Final B&W upscaled file: $OUT"
echo "Work dir (resume/inspection): $WORK_DIR"
