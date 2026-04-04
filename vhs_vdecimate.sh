#!/usr/bin/env bash
set -euo pipefail

IN="${1:?Usage: $0 INPUT.mkv [OUTPUT_VD.mkv]}"
OUT="${2:-${IN%.mkv}_VD.mkv}"

VDECIMATE_VPY="${VDECIMATE_VPY:-$HOME/Videos/vhs-env/tools/vdecimate.vpy}"
VSPipe_BIN="${VSPipe_BIN:-$(command -v vspipe)}"
FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-/usr/bin/ffprobe}"

[[ -f "$IN" ]] || { echo "ERROR: input not found: $IN" >&2; exit 1; }
[[ -f "$VDECIMATE_VPY" ]] || { echo "ERROR: vdecimate.vpy not found: $VDECIMATE_VPY" >&2; exit 1; }
[[ -x "$VSPipe_BIN" ]] || { echo "ERROR: vspipe not executable: $VSPipe_BIN" >&2; exit 1; }
[[ -x "$FFMPEG_BIN" ]] || { echo "ERROR: ffmpeg not executable: $FFMPEG_BIN" >&2; exit 1; }

export VS_INPUT="$IN"
export PYTHONPATH="$HOME/.local/share/vsrepo/py${PYTHONPATH:+:$PYTHONPATH}"

# Write PGID so the process can be paused/stopped externally
_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
echo "$_pgid" > "${HOME}/Videos/logs/vdecimate.pgid"
trap 'rm -f "${HOME}/Videos/logs/vdecimate.pgid"' EXIT

echo "VDecimate:"
echo "  IN:  $IN"
echo "  OUT: $OUT"
echo "  vspipe: $VSPipe_BIN"
echo "  vdecimate.vpy: $VDECIMATE_VPY"
echo "  PGID: $_pgid"
echo

has_audio="$("$FFPROBE_BIN" -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null || true)"

if [[ -n "$has_audio" ]]; then
  "$VSPipe_BIN" -c y4m "$VDECIMATE_VPY" - \
  | "$FFMPEG_BIN" -hide_banner -nostdin -y \
      -thread_queue_size 1024 -f yuv4mpegpipe -i - \
      -thread_queue_size 1024 -i "$IN" \
      -map 0:v:0 -map 1:a:0 \
      -c:v ffv1 -level 3 -pix_fmt yuv422p \
      -c:a copy \
      -shortest \
      "$OUT"
else
  echo "Note: no audio stream in input; writing video-only output."
  "$VSPipe_BIN" -c y4m "$VDECIMATE_VPY" - \
  | "$FFMPEG_BIN" -hide_banner -nostdin -y \
      -thread_queue_size 1024 -f yuv4mpegpipe -i - \
      -c:v ffv1 -level 3 -pix_fmt yuv422p \
      "$OUT"
fi

echo
echo "Done: $OUT"
