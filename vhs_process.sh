#!/usr/bin/env bash
#
# vhs_process.sh
#
# Prep-from-existing (non-destructive):
#   denoise -> QTGMC (auto if interlaced detected) -> handoff to Kdenlive
#
# Defaults (no args):
#   Input selection:
#     1) newest *_STABLE.mkv in ~/Videos/captures/stabilized/
#     2) else newest .mkv in ~/Videos/captures/archival/
#
# Environment:
#   FORCE=1            overwrite outputs (default: 0)
#   REDO_DENOISE=1     re-run denoise even if *_STABLE exists / input already stable
#   REDO_QTGMC=1       re-run QTGMC even if output exists
#   FORCE_QTGMC=1      run QTGMC regardless of idet result
#   SKIP_QTGMC=1       never run QTGMC
#   NO_LAUNCH=1        do not launch Kdenlive (prints path only)
#   QTGMC_FRAMES=600   frames to inspect with idet (default: 600)
#   VPY=...            vapoursynth script (default: ~/Videos/vhs-env/tools/qtgmc.vpy, else ~/Videos/vhs_qtgmc.vpy)
#
set -euo pipefail

VIDEOS="${HOME}/Videos"
CAPTURES="${VIDEOS}/captures"
ARCHIVAL="${CAPTURES}/archival"
STABILIZED="${CAPTURES}/stabilized"
VIEWER="${CAPTURES}/viewer"

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

FFMPEG_BIN="/usr/bin/ffmpeg"
FORCE="${FORCE:-0}"
REDO_DENOISE="${REDO_DENOISE:-0}"
REDO_QTGMC="${REDO_QTGMC:-0}"
FORCE_QTGMC="${FORCE_QTGMC:-0}"
SKIP_QTGMC="${SKIP_QTGMC:-0}"
NO_LAUNCH="${NO_LAUNCH:-0}"
QTGMC_FRAMES="${QTGMC_FRAMES:-600}"

VPY="${VPY:-$HOME/Videos/vhs-env/tools/qtgmc.vpy}"
[[ -f "$VPY" ]] || VPY="$HOME/Videos/vhs_qtgmc.vpy"
[[ -f "$VPY" ]] || { echo "ERROR: QTGMC VPY not found (set VPY)." >&2; exit 1; }

# Input selection
if [[ $# -ge 1 ]]; then
  IN="$1"
else
  IN="$(ls -1t "$STABILIZED"/*_STABLE.mkv 2>/dev/null | head -n 1 || true)"
  [[ -n "$IN" ]] || IN="$(newest_mkv "$ARCHIVAL")"
fi
[[ -n "${IN:-}" ]] || { echo "ERROR: no input found in $STABILIZED or $ARCHIVAL" >&2; exit 1; }
[[ -f "$IN" ]] || { echo "ERROR: input not found: $IN" >&2; exit 1; }

ensure_dir "$STABILIZED"

# Denoise
if [[ "$IN" == *_STABLE.mkv && "$REDO_DENOISE" != "1" ]]; then
  OUT_STABLE="$IN"
  echo "Input is already stable: $OUT_STABLE"
else
  stem="$(stem_of "$IN")"
  OUT_STABLE="$STABILIZED/${stem}_STABLE.mkv"
  if [[ -e "$OUT_STABLE" && "$FORCE" != "1" && "$REDO_DENOISE" != "1" ]]; then
    echo "Reusing existing stable file: $OUT_STABLE"
  else
    FORCE="$FORCE" vhs_stabilize.sh "$IN" "$OUT_STABLE" >/dev/null
  fi
fi

EDIT_IN="$OUT_STABLE"

# QTGMC decision
run_qtgmc=0
if [[ "$SKIP_QTGMC" == "1" ]]; then
  run_qtgmc=0
elif [[ "$FORCE_QTGMC" == "1" ]]; then
  run_qtgmc=1
else
  idet_out="$("$FFMPEG_BIN" -hide_banner -nostdin -i "$OUT_STABLE" -an -vf idet -frames:v "$QTGMC_FRAMES" -f null - 2>&1 | tail -n 60 || true)"
  tff="$(echo "$idet_out" | awk '/Multi frame detection:/ {for(i=1;i<=NF;i++) if($i=="TFF:") print $(i+1)}' | tail -n 1)"
  bff="$(echo "$idet_out" | awk '/Multi frame detection:/ {for(i=1;i<=NF;i++) if($i=="BFF:") print $(i+1)}' | tail -n 1)"
  prog="$(echo "$idet_out" | awk '/Multi frame detection:/ {for(i=1;i<=NF;i++) if($i=="Progressive:") print $(i+1)}' | tail -n 1)"
  und="$(echo "$idet_out" | awk '/Multi frame detection:/ {for(i=1;i<=NF;i++) if($i=="Undetermined:") print $(i+1)}' | tail -n 1)"
  tff=${tff:-0}; bff=${bff:-0}; prog=${prog:-0}; und=${und:-0}
  if [[ $((tff + bff)) -gt "$prog" && $((tff + bff)) -gt 0 ]]; then
    run_qtgmc=1
  fi
  echo "idet decision (frames=$QTGMC_FRAMES): TFF=$tff BFF=$bff Prog=$prog Und=$und => QTGMC=$run_qtgmc"
fi

if [[ "$run_qtgmc" -eq 1 ]]; then
  stable_stem="$(stem_of "$OUT_STABLE")"
  OUT_QTGMC="$STABILIZED/${stable_stem}_QTGMC.mkv"

  if [[ -e "$OUT_QTGMC" && "$FORCE" != "1" && "$REDO_QTGMC" != "1" ]]; then
    echo "Reusing existing QTGMC file: $OUT_QTGMC"
  else
    if out_or_skip "$OUT_QTGMC" "$FORCE"; then
      echo "Running QTGMC..."
      export VS_INPUT="$OUT_STABLE"
      export VS_TFF="${VS_TFF:-1}"
      export VS_FPSDIV="${VS_FPSDIV:-2}"
      export VS_PRESET="${VS_PRESET:-Slower}"
      export PYTHONPATH="$HOME/.local/share/vsrepo/py${PYTHONPATH:+:$PYTHONPATH}"

      vspipe -c y4m "$VPY" - \
        | "$FFMPEG_BIN" -hide_banner -nostdin -y \
            -i - -i "$OUT_STABLE" \
            -map 0:v:0 -map 1:a:0 \
            -c:v ffv1 -level 3 -pix_fmt yuv422p \
            -c:a copy \
            "$OUT_QTGMC"
    fi
  fi
  EDIT_IN="$OUT_QTGMC"
fi

echo
echo "Edit input:"
echo "  $EDIT_IN"
echo

if [[ "$NO_LAUNCH" != "1" ]]; then
  kdenlive "$EDIT_IN" >/dev/null 2>&1 & disown || true
fi

echo "$EDIT_IN"
