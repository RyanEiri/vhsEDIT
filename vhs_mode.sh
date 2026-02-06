#!/usr/bin/env bash
set -euo pipefail

VIDEOS_DIR="${HOME}/Videos"
SLOTS_DIR="${VIDEOS_DIR}/vhs-env"
RESTORE_SCRIPT="${VIDEOS_DIR}/restore_vhs_env.sh"
FFMPEG_CURRENT_LINK="${VIDEOS_DIR}/ffmpeg-current"

# OBS integration (used by the optional "game" mode)
#
# You can override these without editing the script, e.g.:
#   OBS_PROFILE_GAME='GameCapture_1080p60_RAW' vhs_mode.sh game --launch
OBS_BIN="${OBS_BIN:-$(command -v obs || true)}"
OBS_PROFILE_GAME="${OBS_PROFILE_GAME:-GameCapture_1080p60_RAW}"
OBS_COLLECTION_GAME="${OBS_COLLECTION_GAME:-Gameplay_RAW}"

# Prefer your DeckLink-capable ffmpeg, but fall back safely.
FFMPEG_BIN="/usr/local/bin/ffmpeg"
if [ ! -x "$FFMPEG_BIN" ]; then
  FFMPEG_BIN="$(command -v ffmpeg || true)"
fi

usage() {
  cat >&2 <<'EOF'
Usage: vhs_mode.sh {archival|viewer|game} [--launch]

Switches:
  1) OBS + HandBrake config via ~/Videos/restore_vhs_env.sh
  2) ffmpeg capture config by repointing ~/Videos/ffmpeg-current

Additional mode:
  game      Switches to an OBS game-capture profile/collection (no VHS effects).
            With --launch, starts OBS using the configured profile/collection.

Expected slot layout:
  ~/Videos/vhs-env/{archival|viewer}/ffmpeg/capture.env
EOF
  exit 2
}

mode="${1:-}"
launch="${2:-}"
case "$mode" in
  archival|viewer|game) ;;
  -h|--help|"") usage ;;
  *) echo "ERROR: Unknown mode: $mode" >&2; usage ;;
esac

if [ -n "${launch}" ] && [ "${launch}" != "--launch" ]; then
  echo "ERROR: Unknown option: ${launch}" >&2
  usage
fi

# Game mode: do not touch ffmpeg-current; optionally launch OBS with the game-capture profile.
if [ "$mode" = "game" ]; then
  if [ -x "$RESTORE_SCRIPT" ]; then
    # If the restore script supports a "game" slot, it can apply OBS/HandBrake settings.
    # If it doesn't, we'll proceed without failing hard.
    if "$RESTORE_SCRIPT" game 2>/dev/null; then
      :
    else
      echo "NOTE: '$RESTORE_SCRIPT game' returned non-zero; continuing (game mode does not require VHS slots)." >&2
    fi
  else
    echo "NOTE: Missing or not executable: $RESTORE_SCRIPT (continuing; game mode does not require it)." >&2
  fi

  if [ -z "${OBS_BIN}" ] || [ ! -x "${OBS_BIN}" ]; then
    echo "ERROR: 'obs' not found in PATH. Install OBS Studio or set OBS_BIN explicitly." >&2
    exit 1
  fi

  echo "Mode set to: game"
  echo "OBS profile: ${OBS_PROFILE_GAME}"
  echo "OBS scene collection: ${OBS_COLLECTION_GAME}"

  if [ "${launch}" = "--launch" ]; then
    exec "$OBS_BIN" --profile "$OBS_PROFILE_GAME" --collection "$OBS_COLLECTION_GAME"
  fi

  exit 0
fi

slot_ffmpeg_dir="${SLOTS_DIR}/${mode}/ffmpeg"
slot_env="${slot_ffmpeg_dir}/capture.env"

[ -x "$RESTORE_SCRIPT" ] || { echo "ERROR: Missing or not executable: $RESTORE_SCRIPT" >&2; exit 1; }
[ -d "$slot_ffmpeg_dir" ] || { echo "ERROR: Missing slot ffmpeg dir: $slot_ffmpeg_dir" >&2; exit 1; }
[ -f "$slot_env" ] || { echo "ERROR: Missing capture.env: $slot_env" >&2; exit 1; }

# 1) Switch OBS + HandBrake to the requested slot
"$RESTORE_SCRIPT" "$mode"

# 2) Point ffmpeg capture to the requested slot’s config
ln -sfn "$slot_ffmpeg_dir" "$FFMPEG_CURRENT_LINK"

echo "Mode set to: $mode"
echo "ffmpeg config now: ${FFMPEG_CURRENT_LINK}/capture.env"
echo "ffmpeg binary: $FFMPEG_BIN"

# 3) Archival sanity check: ffv1 must exist
# Use a robust match: look for a line whose encoder name is exactly "ffv1"
if [ "$mode" = "archival" ]; then
  if [ -z "${FFMPEG_BIN:-}" ] || [ ! -x "$FFMPEG_BIN" ]; then
    echo "ERROR: ffmpeg not found/executable (expected $FFMPEG_BIN)" >&2
    exit 1
  fi

  if ! "$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qx 'ffv1'; then
    echo "ERROR: ffv1 encoder not available in ${FFMPEG_BIN} (archival mode requires it)" >&2
    echo "Diagnostic: first 30 encoder names:" >&2
    "$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null | awk '{print $2}' | sed -n '1,30p' >&2
    exit 1
  fi
fi

