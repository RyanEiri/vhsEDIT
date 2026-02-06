#!/usr/bin/env bash
#
# vhs_viewer_encode.sh
#
# Plex viewer derivative (non-destructive).
#
# (Patched for B&W support)
#   BW=1 -> forces grayscale video via hue=s=0 (or BW_FILTER override).
#
# Defaults (no args):
#   IN :  ~/Videos/captures/stabilized/EDIT_MASTER.mkv
#         (fallback: newest .mkv in ~/Videos/captures/stabilized/)
#   OUT:  ~/Videos/captures/viewer/EDIT_MASTER.viewer.mkv
#
# Auto behavior:
#   - If input height <= 576  => SD/VHS preset (2-pass ABR + default scale 640x480)
#   - If input height >  576  => HD preset (CRF encode + default no scale)
#
# Override mode:
#   MODE=auto|vhs|hd   (default auto)
#
# Env additions:
#   BW=1               desaturate video (default: 0)
#   BW_FILTER=...      override desat filter (default: hue=s=0)
#
set -euo pipefail

VIDEOS="${HOME}/Videos"
CAPTURES="${VIDEOS}/captures"
STABILIZED="${CAPTURES}/stabilized"
VIEWER="${CAPTURES}/viewer"

FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-/usr/bin/ffprobe}"

FORCE="${FORCE:-0}"
MODE="${MODE:-auto}"              # auto|vhs|hd

# B&W knobs
BW="${BW:-0}"
BW_FILTER="${BW_FILTER:-hue=s=0}"

# Common audio knobs (env overrides supported)
A_BR="${A_BR:-320k}"
A_AAC_CODER="${A_AAC_CODER:-twoloop}"
A_AAC_CUTOFF="${A_AAC_CUTOFF:-20000}"

# Deinterlace control (mostly relevant for SD captures)
DEINTERLACE="${DEINTERLACE:-off}" # auto|on|off

newest_mkv() {
  local dir="$1"
  ls -1t "$dir"/*.mkv 2>/dev/null | head -n 1
}

stem_of() {
  local f; f="$(basename "$1")"
  echo "${f%.mkv}"
}

ensure_dir() {
  [[ -d "$1" ]] || mkdir -p "$1"
}

out_or_skip() {
  local out="$1" force="${2:-0}"
  if [[ -e "$out" && "$force" != "1" ]]; then
    echo "Exists, skipping (FORCE=1 to overwrite): $out" >&2
    return 1
  fi
  return 0
}

probe_video() {
  "$FFPROBE_BIN" -v error \
    -select_streams v:0 \
    -show_entries stream=width,height,avg_frame_rate \
    -of default=nw=1:nk=1 \
    "$1" | awk 'NR==1{w=$0} NR==2{h=$0} NR==3{r=$0}
      END{
        split(r,a,"/")
        if (a[2] > 0) fps=a[1]/a[2]; else fps=0
        printf "%s %s %.6f\n", w, h, fps
      }'
}

pick_cfr() {
  local fps="$1"
  awk -v f="$fps" 'BEGIN{
    if (f>29.0 && f<30.2) { print "30000/1001"; exit }
    if (f>59.0 && f<60.2) { print "60000/1001"; exit }
    if (f>23.5 && f<24.2) { print "24000/1001"; exit }
    if (f>49.0 && f<50.2) { print "50"; exit }
    n = int(f + 0.5)
    if (n < 1) n = 30
    print n
  }'
}

ensure_dir "$VIEWER"

DEFAULT_IN="$STABILIZED/EDIT_MASTER.mkv"
DEFAULT_OUT="$VIEWER/EDIT_MASTER.viewer.mkv"

if [[ $# -eq 0 ]]; then
  IN="$DEFAULT_IN"
  OUT="$DEFAULT_OUT"
elif [[ $# -eq 1 ]]; then
  IN="$1"
  base="$(stem_of "$IN")"
  OUT="$VIEWER/${base}.viewer.mkv"
elif [[ $# -eq 2 ]]; then
  IN="$1"
  OUT="$2"
else
  echo "Usage: $0 [INPUT [OUTPUT.mkv]]" >&2
  exit 1
fi

if [[ ! -f "$IN" ]]; then
  IN="$(newest_mkv "$STABILIZED")"
fi
[[ -n "${IN:-}" && -f "$IN" ]] || { echo "ERROR: input not found and no stabilized MKVs available" >&2; exit 1; }

if ! out_or_skip "$OUT" "$FORCE"; then
  echo "$OUT"
  exit 0
fi

read -r SRC_W SRC_H SRC_FPS < <(probe_video "$IN")

if [[ "$MODE" == "auto" ]]; then
  if [[ "${SRC_H:-0}" -le 576 ]]; then MODE="vhs"; else MODE="hd"; fi
fi
if [[ "$MODE" != "vhs" && "$MODE" != "hd" ]]; then
  echo "ERROR: MODE must be auto|vhs|hd (got: $MODE)" >&2
  exit 1
fi

V_PRESET="${V_PRESET:-}"
V_PROFILE="${V_PROFILE:-}"
V_LEVEL="${V_LEVEL:-}"
V_FPS="${V_FPS:-}"
SCALE="${SCALE:-}"
V_BK="${V_BK:-}"
V_CRF="${V_CRF:-}"
V_MAXRATE="${V_MAXRATE:-}"
V_BUFSIZE="${V_BUFSIZE:-}"

if [[ "$MODE" == "vhs" ]]; then
  V_PRESET="${V_PRESET:-fast}"
  V_PROFILE="${V_PROFILE:-main}"
  V_LEVEL="${V_LEVEL:-4.0}"
  V_BK="${V_BK:-2000k}"
  SCALE="${SCALE:-640:480}"
  if [[ -z "$V_FPS" ]]; then V_FPS="30000/1001"; fi
else
  V_PRESET="${V_PRESET:-medium}"
  V_PROFILE="${V_PROFILE:-high}"
  V_LEVEL="${V_LEVEL:-4.1}"
  V_CRF="${V_CRF:-20}"
  SCALE="${SCALE:-}"
  if [[ -z "$V_FPS" ]]; then V_FPS="$(pick_cfr "${SRC_FPS:-0}")"; fi
  V_MAXRATE="${V_MAXRATE:-}"
  V_BUFSIZE="${V_BUFSIZE:-}"
fi

vf_parts=()
want_bwdif=0

if [[ "$DEINTERLACE" == "on" ]]; then
  want_bwdif=1
elif [[ "$DEINTERLACE" == "auto" ]]; then
  idet_out="$("$FFMPEG_BIN" -hide_banner -nostdin -i "$IN" -an -vf idet -frames:v 600 -f null - 2>&1 | tail -n 60 || true)"
  tff="$(echo "$idet_out" | awk '/Multi frame detection:/ {for(i=1;i<=NF;i++) if($i=="TFF:") print $(i+1)}' | tail -n 1)"
  bff="$(echo "$idet_out" | awk '/Multi frame detection:/ {for(i=1;i<=NF;i++) if($i=="BFF:") print $(i+1)}' | tail -n 1)"
  prog="$(echo "$idet_out" | awk '/Multi frame detection:/ {for(i=1;i<=NF;i++) if($i=="Progressive:") print $(i+1)}' | tail -n 1)"
  tff=${tff:-0}; bff=${bff:-0}; prog=${prog:-0}
  if [[ $((tff + bff)) -gt "$prog" && $((tff + bff)) -gt 0 ]]; then want_bwdif=1; fi
elif [[ "$DEINTERLACE" == "off" ]]; then
  want_bwdif=0
else
  echo "ERROR: DEINTERLACE must be auto|on|off (got: $DEINTERLACE)" >&2
  exit 1
fi

if [[ "$want_bwdif" -eq 1 ]]; then
  vf_parts+=("bwdif=mode=0:parity=auto:deint=all")
fi

# B&W first so scaling/sharpening doesn't see chroma noise edges
if [[ "$BW" == "1" ]]; then
  vf_parts+=("${BW_FILTER}")
fi

if [[ -n "$SCALE" ]]; then
  vf_parts+=("scale=${SCALE}:flags=lanczos")
fi
vf_parts+=("setsar=1")
vf_parts+=("format=yuv420p")
VF="$(IFS=,; echo "${vf_parts[*]}")"

AF="aresample=async=1:first_pts=0,asetpts=N/SR/TB"

echo "Viewer encode (ffmpeg)"
echo "  Mode:      $MODE (src=${SRC_W}x${SRC_H} @ ${SRC_FPS}fps)"
echo "  BW:        $BW"
echo "  IN:        $IN"
echo "  OUT:       $OUT"
echo "  VF:        $VF"
echo "  CFR:       $V_FPS"
echo "  Audio:     AAC $A_BR"
echo

if [[ "$MODE" == "vhs" ]]; then
  echo "  Video:     x264 2-pass ABR $V_BK preset=$V_PRESET profile=$V_PROFILE level=$V_LEVEL"
  passlog="${OUT%.*}.x264pass"

  "$FFMPEG_BIN" -hide_banner -nostdin -y \
    -fflags +genpts -i "$IN" \
    -map 0:v:0 \
    -vf "$VF" \
    -fps_mode cfr -r "$V_FPS" \
    -c:v libx264 -preset "$V_PRESET" -profile:v "$V_PROFILE" -level:v "$V_LEVEL" \
    -b:v "$V_BK" -maxrate "$V_BK" -bufsize "$V_BK" \
    -pass 1 -passlogfile "$passlog" \
    -an -f matroska /dev/null

  "$FFMPEG_BIN" -hide_banner -nostdin -y \
    -fflags +genpts -i "$IN" \
    -map 0:v:0 -map 0:a:0 \
    -vf "$VF" \
    -fps_mode cfr -r "$V_FPS" \
    -c:v libx264 -preset "$V_PRESET" -profile:v "$V_PROFILE" -level:v "$V_LEVEL" \
    -b:v "$V_BK" -maxrate "$V_BK" -bufsize "$V_BK" \
    -pass 2 -passlogfile "$passlog" \
    -c:a aac -profile:a aac_low -b:a "$A_BR" -aac_coder "$A_AAC_CODER" -cutoff "$A_AAC_CUTOFF" \
    -af "$AF" -ar 48000 -ac 2 \
    "$OUT"

  rm -f "${passlog}" "${passlog}.mbtree" 2>/dev/null || true
else
  echo "  Video:     x264 CRF $V_CRF preset=$V_PRESET profile=$V_PROFILE level=$V_LEVEL"

  rate_args=()
  if [[ -n "${V_MAXRATE}" ]]; then rate_args+=(-maxrate "$V_MAXRATE"); fi
  if [[ -n "${V_BUFSIZE}" ]]; then rate_args+=(-bufsize "$V_BUFSIZE"); fi

  "$FFMPEG_BIN" -hide_banner -nostdin -y \
    -fflags +genpts -i "$IN" \
    -map 0:v:0 -map 0:a:0 \
    -vf "$VF" \
    -fps_mode cfr -r "$V_FPS" \
    -c:v libx264 -preset "$V_PRESET" -profile:v "$V_PROFILE" -level:v "$V_LEVEL" \
    -crf "$V_CRF" "${rate_args[@]}" \
    -c:a aac -profile:a aac_low -b:a "$A_BR" -aac_coder "$A_AAC_CODER" -cutoff "$A_AAC_CUTOFF" \
    -af "$AF" -ar 48000 -ac 2 \
    "$OUT"
fi

echo
echo "$OUT"
