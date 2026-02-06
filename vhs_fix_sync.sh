#!/usr/bin/env bash
#
# vhs_fix_sync.sh
#
# Correct *drift* between audio + video using ffmpeg.
#
# - Derives stream durations robustly:
#     1) stream.duration (if numeric)
#     2) stream_tags:DURATION (if present; hh:mm:ss.ms)
#     3) duration_ts * time_base (if present)
#     4) format.duration as last resort
#
# - Computes atempo so audio length matches video length
# - Copies video, re-encodes audio
#
# Requirements: ffmpeg, ffprobe, awk

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 input_file output_file" >&2
  exit 1
fi

IN="$1"
OUT="$2"

command -v ffprobe >/dev/null 2>&1 || { echo "Error: ffprobe not found in PATH." >&2; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }

is_number() {
  awk -v x="${1:-}" 'BEGIN{
    if (x=="" || x=="N/A") exit 1
    # numeric (int/float) test
    exit (x ~ /^-?[0-9]+([.][0-9]+)?$/) ? 0 : 1
  }'
}

hms_to_seconds() {
  # input: HH:MM:SS.mmm (or with more decimals)
  awk -v t="${1:-}" 'BEGIN{
    if (t=="" || t=="N/A") { exit 1 }
    n = split(t, a, ":")
    if (n != 3) { exit 1 }
    h=a[1]+0; m=a[2]+0; s=a[3]+0
    printf "%.8f", (h*3600.0 + m*60.0 + s)
  }'
}

duration_ts_to_seconds() {
  # inputs: duration_ts, time_base (e.g., 1/1000)
  awk -v dts="${1:-}" -v tb="${2:-}" 'BEGIN{
    if (dts=="" || dts=="N/A") exit 1
    if (tb==""  || tb=="N/A")  exit 1
    n = split(tb, f, "/")
    if (n != 2) exit 1
    num = f[1]+0; den = f[2]+0
    if (den == 0) exit 1
    printf "%.8f", (dts * num / den)
  }'
}

get_stream_duration_seconds() {
  # $1 = stream selector: v:0 or a:0
  local sel="$1"

  # 1) stream.duration
  local d
  d="$(ffprobe -v error -select_streams "$sel" \
        -show_entries stream=duration \
        -of default=nk=1:nw=1 "$IN" | head -n1 || true)"
  if is_number "$d"; then
    echo "$d"
    return 0
  fi

  # 2) stream_tags:DURATION (common in Matroska)
  local tag
  tag="$(ffprobe -v error -select_streams "$sel" \
          -show_entries stream_tags=DURATION \
          -of default=nk=1:nw=1 "$IN" | head -n1 || true)"
  if hms_to_seconds "$tag" >/dev/null 2>&1; then
    hms_to_seconds "$tag"
    return 0
  fi

  # 3) duration_ts * time_base
  local dts tb
  dts="$(ffprobe -v error -select_streams "$sel" \
          -show_entries stream=duration_ts \
          -of default=nk=1:nw=1 "$IN" | head -n1 || true)"
  tb="$(ffprobe -v error -select_streams "$sel" \
         -show_entries stream=time_base \
         -of default=nk=1:nw=1 "$IN" | head -n1 || true)"
  if duration_ts_to_seconds "$dts" "$tb" >/dev/null 2>&1; then
    duration_ts_to_seconds "$dts" "$tb"
    return 0
  fi

  # 4) format.duration fallback (least informative, but prevents crashes)
  local fmt
  fmt="$(ffprobe -v error -show_entries format=duration \
         -of default=nk=1:nw=1 "$IN" | head -n1 || true)"
  if is_number "$fmt"; then
    echo "$fmt"
    return 0
  fi

  return 1
}

echo ">>> Analyzing durations for:"
echo "    $IN"
echo

v_dur="$(get_stream_duration_seconds v:0 || true)"
a_dur="$(get_stream_duration_seconds a:0 || true)"

if ! is_number "$v_dur" || ! is_number "$a_dur"; then
  echo "Error: Could not determine numeric durations (v='$v_dur', a='$a_dur')." >&2
  echo "Tip: run: ffprobe -hide_banner -show_streams -show_format \"$IN\" | less" >&2
  exit 1
fi

echo "Video duration : $v_dur s"
echo "Audio duration : $a_dur s"

# tempo = a_dur / v_dur  (since new_audio_dur = old_audio_dur / tempo)
tempo="$(awk -v vd="$v_dur" -v ad="$a_dur" 'BEGIN{
  if (vd <= 0) { print "1.00000000"; exit }
  printf "%.8f", (ad / vd)
}')"

diff_pct="$(awk -v t="$tempo" 'BEGIN{
  d = (t > 1.0) ? (t - 1.0) : (1.0 - t);
  printf "%.3f", d * 100.0
}')"

echo "Computed audio tempo factor: $tempo (drift ≈ ${diff_pct}%)"

# If drift is tiny, just warn and exit.
if awk -v d="$diff_pct" 'BEGIN{exit (d < 0.001 ? 0 : 1)}'; then
  echo "Drift is less than 0.001% – probably not worth correcting."
  echo "No output written. Adjust threshold if you want to force correction."
  exit 0
fi

# atempo supports ~0.5..2.0 per instance; if outside, chain factors.
build_atempo_chain() {
  awk -v t="$1" 'BEGIN{
    if (t<=0) { print "atempo=1.0"; exit }
    # build a chain like atempo=2.0,atempo=1.2345
    out=""
    while (t > 2.0) {
      out = out (out=="" ? "" : ",") "atempo=2.0"
      t = t / 2.0
    }
    while (t < 0.5) {
      out = out (out=="" ? "" : ",") "atempo=0.5"
      t = t / 0.5
    }
    out = out (out=="" ? "" : ",") "atempo=" sprintf("%.8f", t)
    print out
  }'
}

atempo_chain="$(build_atempo_chain "$tempo")"

echo
echo ">>> Writing drift-corrected file to:"
echo "    $OUT"
echo "    (video: copy, audio: $atempo_chain + aresample=async=1:first_pts=0)"
echo

ffmpeg -y -i "$IN" \
  -map 0:v:0 -map 0:a:0 \
  -c:v copy \
  -af "${atempo_chain},aresample=async=1:first_pts=0" \
  -c:a aac -b:a 192k \
  "$OUT"

echo
echo "Done."
echo "Original : $IN"
echo "Corrected: $OUT"

