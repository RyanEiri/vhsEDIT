#!/usr/bin/env bash
#
# vhs_probe_crush.sh
#
# Probes luma statistics for a VHS input and recommends a black crush
# point for the PRE_VF curves filter used in the upscale scripts.
#
# Samples a window of frames at a reduced frame rate, collects per-frame
# YLOW (the 10th-percentile luma value within each frame), takes the
# DARK_PERCENTILE-th percentile of those values as an estimate of the
# noise floor in genuinely dark content, then computes a crush point
# just below that level.
#
# Usage:
#   ./vhs_probe_crush.sh INPUT [sample_offset] [sample_duration]
#
# Defaults:
#   sample_offset   = 60   (seconds; skips opening logos/tracking noise)
#   sample_duration = 120  (seconds to sample)
#
# Environment variables (all optional):
#   SAMPLE_OFFSET    seconds into video to start sampling (default: 60)
#   SAMPLE_DURATION  seconds to analyse (default: 120)
#   SAMPLE_FPS       probe frame rate in fps (default: 2)
#   DARK_PERCENTILE  percentile of YLOW values used as the noise floor
#                    estimate (default: 10; lower = more conservative crush)
#   MARGIN           scale factor applied to the raw crush value to keep
#                    the crush point safely below the noise floor
#                    (default: 0.85)
#
# Output:
#   Recommended PRE_VF string  → stdout  (suitable for capture/export)
#   Diagnostic luma statistics → stderr
#
# Example:
#   PRE_VF="$(./vhs_probe_crush.sh captures/stabilized/EDIT_MASTER.mkv)"
#   PRE_VF="$PRE_VF" ./vhs_upscale.sh captures/stabilized/EDIT_MASTER.mkv out.mkv
#
# Requirements:
#   - ffmpeg, ffprobe, awk

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 INPUT [sample_offset] [sample_duration]" >&2
  exit 1
fi

IN="$1"
SAMPLE_OFFSET="${2:-${SAMPLE_OFFSET:-60}}"
SAMPLE_DURATION="${3:-${SAMPLE_DURATION:-120}}"
SAMPLE_FPS="${SAMPLE_FPS:-2}"
DARK_PERCENTILE="${DARK_PERCENTILE:-10}"
MARGIN="${MARGIN:-0.85}"

FFMPEG="/usr/bin/ffmpeg"
FFPROBE="/usr/bin/ffprobe"

[ -x "$FFMPEG" ]  || { echo "Error: $FFMPEG not found." >&2; exit 1; }
[ -x "$FFPROBE" ] || { echo "Error: $FFPROBE not found." >&2; exit 1; }
[ -f "$IN" ]      || { echo "Error: input '$IN' not found." >&2; exit 1; }

# Validate offset against video duration
duration="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$IN" || true)"
[ -z "${duration:-}" ] && { echo "Error: could not determine input duration." >&2; exit 1; }
total_s="$(awk -v d="$duration" 'BEGIN{printf "%d", d}')"

[ "$SAMPLE_OFFSET" -ge "$total_s" ] && {
  echo "Error: SAMPLE_OFFSET (${SAMPLE_OFFSET}s) >= video duration (${total_s}s)." >&2
  exit 1
}

# Clamp sample duration to available content
avail=$(( total_s - SAMPLE_OFFSET ))
if [ "$SAMPLE_DURATION" -gt "$avail" ]; then
  SAMPLE_DURATION=$avail
  echo "Warning: clamped SAMPLE_DURATION to ${SAMPLE_DURATION}s (end of file)." >&2
fi

echo ">>> vhs_probe_crush" >&2
echo "    Input           : $IN" >&2
echo "    Offset          : ${SAMPLE_OFFSET}s" >&2
echo "    Duration        : ${SAMPLE_DURATION}s" >&2
echo "    Sample rate     : ${SAMPLE_FPS}fps" >&2
echo "    Dark percentile : ${DARK_PERCENTILE}" >&2
echo "    Margin          : ${MARGIN}" >&2
echo >&2

# Collect YLOW values from sampled frames.
# YLOW = 10th-percentile luma value within each frame (ffmpeg signalstats).
ylow_values="$(
  "$FFMPEG" -hide_banner \
    -ss "$SAMPLE_OFFSET" \
    -t  "$SAMPLE_DURATION" \
    -i  "$IN" \
    -an \
    -vf "fps=${SAMPLE_FPS},signalstats,metadata=print:file=-" \
    -f  null - 2>/dev/null \
  | awk -F= '/lavfi\.signalstats\.YLOW/{print $2}'
)"

[ -z "${ylow_values:-}" ] && { echo "Error: no luma data extracted — check input file." >&2; exit 1; }

# Compute statistics and crush point.
# Outputs crush value (e.g. "0.04") to stdout; diagnostics to stderr.
crush="$(awk \
  -v pct="$DARK_PERCENTILE" \
  -v margin="$MARGIN" \
'
{ values[NR-1] = $1 + 0 }
END {
  n = NR
  if (n == 0) { print "Error: empty dataset" > "/dev/stderr"; exit 1 }

  # Insertion sort (sample sizes are small — a few hundred frames)
  for (i = 1; i < n; i++) {
    key = values[i]; j = i - 1
    while (j >= 0 && values[j] > key) { values[j+1] = values[j]; j-- }
    values[j+1] = key
  }

  ymin  = values[0]
  ymax  = values[n-1]
  ymid  = (n % 2 == 1) ? values[int(n/2)] \
                        : (values[n/2-1] + values[n/2]) / 2.0

  p_idx = int(n * pct / 100 + 0.5)
  if (p_idx >= n) p_idx = n - 1
  p_val = values[p_idx]

  raw   = (p_val / 255.0) * margin
  if (raw < 0.01) raw = 0.01
  if (raw > 0.10) raw = 0.10
  crush = int(raw * 100 + 0.5) / 100.0

  printf "Frames sampled  : %d\n",         n             > "/dev/stderr"
  printf "YLOW min        : %d\n",          ymin          > "/dev/stderr"
  printf "YLOW median     : %.1f\n",        ymid          > "/dev/stderr"
  printf "YLOW max        : %d\n",          ymax          > "/dev/stderr"
  printf "YLOW %d%%ile    : %d\n",          pct, p_val    > "/dev/stderr"
  printf "Crush raw       : %.4f\n",        raw           > "/dev/stderr"
  printf "Crush point     : %.2f\n",        crush         > "/dev/stderr"
  printf "\n"                                             > "/dev/stderr"

  printf "%.2f\n", crush
}
' <<< "$ylow_values")"

PRE_VF_OUT="hqdn3d=3:2:4:3,curves=all='0/0 ${crush}/0 1/1'"

echo "Recommended PRE_VF:" >&2
echo "  $PRE_VF_OUT" >&2
echo >&2
echo "To use:" >&2
echo "  PRE_VF=\"$PRE_VF_OUT\" ./vhs_upscale.sh INPUT OUTPUT" >&2
echo >&2

# Emit PRE_VF value to stdout for capture/scripting
echo "$PRE_VF_OUT"
