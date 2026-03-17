#!/usr/bin/env bash
set -euo pipefail

# vhs_ivtc_decombed.sh
#
# IVTC with QTGMC decombing for combed frames.
# Same as vhs_ivtc.sh but uses ivtc_decombed.vpy which applies QTGMC
# selectively to frames that VFM couldn't cleanly field-match.
#
# Environment variables (optional):
#   VS_TFF             Field order: 1=TFF (default), 0=BFF
#   VS_DECOMB_PRESET   QTGMC preset for decombing (default: Fast)

IN="${1:?Usage: $0 INPUT_STABLE.mkv [OUTPUT_IVTC.mkv]}"
OUT="${2:-${IN%.mkv}_IVTC_DECOMBED.mkv}"

IVTC_VPY="${IVTC_VPY:-$HOME/Videos/vhs-env/tools/ivtc_decombed.vpy}"
VSPipe_BIN="${VSPipe_BIN:-$(command -v vspipe)}"
FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"

VS_TFF="${VS_TFF:-1}"
VS_DECOMB_PRESET="${VS_DECOMB_PRESET:-Fast}"

[[ -f "$IN" ]] || { echo "ERROR: input not found: $IN" >&2; exit 1; }
[[ -f "$IVTC_VPY" ]] || { echo "ERROR: ivtc_decombed.vpy not found: $IVTC_VPY" >&2; exit 1; }
[[ -x "$VSPipe_BIN" ]] || { echo "ERROR: vspipe not executable: $VSPipe_BIN" >&2; exit 1; }
[[ -x "$FFMPEG_BIN" ]] || { echo "ERROR: ffmpeg not executable: $FFMPEG_BIN" >&2; exit 1; }

export VS_INPUT="$IN"
export VS_TFF="$VS_TFF"
export VS_DECOMB_PRESET="$VS_DECOMB_PRESET"
export PYTHONPATH="$HOME/.local/share/vsrepo/py${PYTHONPATH:+:$PYTHONPATH}"

echo "IVTC + decomb:"
echo "  IN:              $IN"
echo "  OUT:             $OUT"
echo "  vspipe:          $VSPipe_BIN"
echo "  ivtc_decombed:   $IVTC_VPY"
echo "  VS_TFF=          $VS_TFF"
echo "  VS_DECOMB_PRESET=$VS_DECOMB_PRESET"
echo

"$VSPipe_BIN" -c y4m "$IVTC_VPY" - \
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
