#!/usr/bin/env bash
set -euo pipefail

CFG_FILE="${HOME}/Videos/ffmpeg-current/capture.env"
[ -f "$CFG_FILE" ] || { echo "Missing $CFG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CFG_FILE"

# ffmpeg selection: slot env → /usr/local → PATH
FFMPEG_BIN="${VHS_FFMPEG_BIN:-/usr/local/bin/ffmpeg}"
FFPROBE_BIN="${VHS_FFPROBE_BIN:-/usr/local/bin/ffprobe}"

[ -x "$FFMPEG_BIN" ]  || FFMPEG_BIN="$(command -v ffmpeg)"
[ -x "$FFPROBE_BIN" ] || FFPROBE_BIN="$(command -v ffprobe)"

ts="$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$VHS_OUTDIR" "${HOME}/Videos/logs"

out="${VHS_OUTDIR}/${VHS_PREFIX}_${ts}.mkv"
log="${HOME}/Videos/logs/${VHS_PREFIX}_${ts}.ffmpeg.log"

echo "Using:   $CFG_FILE"
echo "ffmpeg:  $FFMPEG_BIN"
echo "Video:   $VHS_V4L2_DEV ($VHS_INPUT_FMT $VHS_SIZE @ $VHS_FPS)"
echo "Audio:   $VHS_ALSA_DEV ($VHS_AR Hz, $VHS_AC ch)"
echo "Codec:   $VHS_VCODEC (${VHS_PIXFMT})"
echo "Output:  $out"
echo "Log:     $log"
echo

video_in=(
  -f v4l2
  -use_wallclock_as_timestamps 1
  -thread_queue_size 1024
  -input_format "$VHS_INPUT_FMT"
  -video_size "$VHS_SIZE"
  -framerate "$VHS_FPS"
  -i "$VHS_V4L2_DEV"
)

audio_in=(
  -f alsa
  -use_wallclock_as_timestamps 1
  -thread_queue_size 1024
  -ar "$VHS_AR"
  -ac "$VHS_AC"
  -i "$VHS_ALSA_DEV"
)

map_and_audio=(
  -map 0:v:0
  -map 1:a:0
  -c:a pcm_s16le
)

color_tags=(
  -color_range "$VHS_COLOR_RANGE"
  -color_primaries "$VHS_COLOR_PRIM"
  -color_trc "$VHS_COLOR_TRC"
  -colorspace "$VHS_COLOR_SPACE"
)

video_codec=()
case "$VHS_VCODEC" in
  ffv1)
    video_codec=(
      -c:v ffv1
      -level:v "${VHS_FFV1_LEVEL:-3}"
      -g:v 1
      -slices:v "${VHS_FFV1_SLICES:-16}"
      -slicecrc:v 1
      -pix_fmt "$VHS_PIXFMT"
    )
    ;;
  libx264)
    video_codec=(
      -c:v libx264
      -preset "${VHS_X264_PRESET:-veryfast}"
      -crf "${VHS_X264_CRF:-18}"
      -pix_fmt "$VHS_PIXFMT"
    )
    ;;
  *)
    echo "ERROR: Unsupported VHS_VCODEC='$VHS_VCODEC' (expected: ffv1 | libx264)" >&2
    exit 1
    ;;
esac

"$FFMPEG_BIN" -hide_banner -nostdin \
  "${video_in[@]}" \
  "${audio_in[@]}" \
  "${map_and_audio[@]}" \
  "${video_codec[@]}" \
  "${color_tags[@]}" \
  -max_interleave_delta 0 \
  -fflags +genpts \
  -fps_mode cfr \
  "$out" 2>&1 | tee "$log"

echo
"$FFPROBE_BIN" -hide_banner "$out" | sed -n '1,25p'

