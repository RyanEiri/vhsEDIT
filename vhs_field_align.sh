#!/usr/bin/env bash
set -euo pipefail

# vhs_field_align.sh
#
# Corrects interlaced field misalignment (horizontal stepping) in VHS captures.
# Separates fields, applies a sub-pixel horizontal shift to one field, re-weaves.
#
# Usage:
#   ./vhs_field_align.sh INPUT.mkv [OUTPUT.mkv]
#
# Environment variables (optional):
#   VS_FIELD_SHIFT   Pixels to shift (float, default: 1.0). Positive = rightward.
#   VS_SHIFT_FIELD   Which field to shift: "top" or "bottom" (default: bottom)
#   VS_TFF           Field order: 1=TFF, 0=BFF (default: 1)

IN="${1:?Usage: $0 INPUT.mkv [OUTPUT.mkv]}"
OUT="${2:-${IN%.mkv}_ALIGNED.mkv}"

FIELD_ALIGN_VPY="${FIELD_ALIGN_VPY:-$HOME/Videos/vhs-env/tools/field_align.vpy}"
VSPipe_BIN="${VSPipe_BIN:-$(command -v vspipe)}"
FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"

VS_TFF="${VS_TFF:-1}"
VS_FIELD_SHIFT="${VS_FIELD_SHIFT:-1.0}"
VS_SHIFT_FIELD="${VS_SHIFT_FIELD:-bottom}"

[[ -f "$IN" ]] || { echo "ERROR: input not found: $IN" >&2; exit 1; }
[[ -f "$FIELD_ALIGN_VPY" ]] || { echo "ERROR: field_align.vpy not found: $FIELD_ALIGN_VPY" >&2; exit 1; }
[[ -x "$VSPipe_BIN" ]] || { echo "ERROR: vspipe not executable: $VSPipe_BIN" >&2; exit 1; }
[[ -x "$FFMPEG_BIN" ]] || { echo "ERROR: ffmpeg not executable: $FFMPEG_BIN" >&2; exit 1; }

export VS_INPUT="$IN"
export VS_TFF="$VS_TFF"
export VS_FIELD_SHIFT="$VS_FIELD_SHIFT"
export VS_SHIFT_FIELD="$VS_SHIFT_FIELD"
export PYTHONPATH="$HOME/.local/share/vsrepo/py${PYTHONPATH:+:$PYTHONPATH}"

# Write PGID so the process can be paused/stopped externally
_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
echo "$_pgid" > "${HOME}/Videos/logs/field_align.pgid"
trap 'rm -f "${HOME}/Videos/logs/field_align.pgid"' EXIT

echo "Field alignment:"
echo "  IN:             $IN"
echo "  OUT:            $OUT"
echo "  VS_FIELD_SHIFT: $VS_FIELD_SHIFT"
echo "  VS_SHIFT_FIELD: $VS_SHIFT_FIELD"
echo "  VS_TFF:         $VS_TFF"
echo "  PGID:           $_pgid"
echo

"$VSPipe_BIN" -c y4m "$FIELD_ALIGN_VPY" - \
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
