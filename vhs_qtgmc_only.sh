#!/usr/bin/env bash
set -euo pipefail

IN="${1:?Usage: $0 INPUT_STABLE.mkv [OUTPUT_QTGMC.mkv]}"
OUT="${2:-${IN%.mkv}_QTGMC.mkv}"

QTGMC_VPY="${QTGMC_VPY:-$HOME/Videos/vhs-env/tools/qtgmc.vpy}"
VSPipe_BIN="${VSPipe_BIN:-$(command -v vspipe)}"
FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"

VS_TFF="${VS_TFF:-1}"
VS_FPSDIV="${VS_FPSDIV:-2}"
VS_PRESET="${VS_PRESET:-Slower}"

[[ -f "$IN" ]] || { echo "ERROR: input not found: $IN" >&2; exit 1; }
[[ -f "$QTGMC_VPY" ]] || { echo "ERROR: qtgmc.vpy not found: $QTGMC_VPY" >&2; exit 1; }
[[ -x "$VSPipe_BIN" ]] || { echo "ERROR: vspipe not executable: $VSPipe_BIN" >&2; exit 1; }
[[ -x "$FFMPEG_BIN" ]] || { echo "ERROR: ffmpeg not executable: $FFMPEG_BIN" >&2; exit 1; }

# Do NOT export PYTHONPATH here. Mixing site-packages is a common cause of "Failed to initialize VSScript".
export VS_INPUT="$IN"
export VS_TFF="$VS_TFF"
export VS_FPSDIV="$VS_FPSDIV"
export VS_PRESET="$VS_PRESET"
export PYTHONPATH="$HOME/.local/share/vsrepo/py${PYTHONPATH:+:$PYTHONPATH}"

echo "QTGMC only:"
echo "  IN:  $IN"
echo "  OUT: $OUT"
echo "  vspipe: $VSPipe_BIN"
echo "  qtgmc.vpy: $QTGMC_VPY"
echo "  VS_TFF=$VS_TFF VS_FPSDIV=$VS_FPSDIV VS_PRESET=$VS_PRESET"
echo

"$VSPipe_BIN" -c y4m "$QTGMC_VPY" - \
| "$FFMPEG_BIN" -hide_banner -nostdin -y \
    -thread_queue_size 1024 -f yuv4mpegpipe -i - \
    -thread_queue_size 1024 -i "$IN" \
    -map 0:v:0 -map 1:a:0 \
    -c:v ffv1 -level 3 -pix_fmt yuv422p \
    -c:a copy \
    -shortest \
    "$OUT"

echo
echo "Done: $OUT"

