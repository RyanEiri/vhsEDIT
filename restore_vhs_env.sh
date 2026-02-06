#!/usr/bin/env bash
set -euo pipefail

# Restore OBS + HandBrake (Flatpak) configuration from either:
#   1) a named slot under ~/Videos/vhs-env/{archival|viewer|game}, or
#   2) a timestamped backup directory under ~/Videos/backups/vhs-env-*
#
# Usage:
#   ./restore_vhs_env.sh archival
#   ./restore_vhs_env.sh viewer
#   ./restore_vhs_env.sh game
#   ./restore_vhs_env.sh /home/you/Videos/backups/vhs-env-YYYY-mm-dd_HH-MM-SS[-slot]
#   ./restore_vhs_env.sh            # restore from most recent timestamped backup

VIDEOS_ROOT="${HOME}/Videos"
BACKUP_ROOT="${VIDEOS_ROOT}/backups"
SLOTS_ROOT="${VIDEOS_ROOT}/vhs-env"

OBS_DST="${HOME}/.config/obs-studio"
HB_DST="${HOME}/.var/app/fr.handbrake.ghb"

ARG="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

latest_backup() {
  # Find most recent vhs-env-* directory under BACKUP_ROOT
  ls -1dt "${BACKUP_ROOT}"/vhs-env-* 2>/dev/null | head -n 1 || true
}

ensure_not_running() {
  local name="$1"
  local proc="$2"
  if pgrep -x "$proc" >/dev/null 2>&1; then
    die "${name} appears to be running ('${proc}'). Close it before restoring."
  fi
}

restore_tree() {
  # restore_tree SRC DST LABEL
  local src="$1"
  local dst="$2"
  local label="$3"

  if [ ! -d "$src" ]; then
    echo "  - ${label} not found in backup (skipping): $src"
    return 0
  fi

  # Safety: move current config aside before overwriting
  if [ -d "$dst" ]; then
    local moved="${dst}.PRE-RESTORE.$(date +%Y-%m-%d_%H-%M-%S)"
    echo "  - Moving existing ${label} aside:"
    echo "      ${dst} -> ${moved}"
    mv "$dst" "$moved"
  fi

  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  echo "  - Restored ${label} to: $dst"
}

# Determine source directory
SRC_DIR=""
if [ -z "${ARG}" ]; then
  SRC_DIR="$(latest_backup)"
  [ -n "$SRC_DIR" ] || die "No backups found under ${BACKUP_ROOT}."
else
  case "${ARG}" in
    archival|viewer)
      SRC_DIR="${SLOTS_ROOT}/${ARG}"
      [ -d "$SRC_DIR" ] || die "Slot '${ARG}' not found at ${SRC_DIR}. Run backup_vhs_env.sh ${ARG} first."
      ;;
    game)
      # 'game' is an optional slot used to restore a clean OBS configuration suitable for
      # digital game capture. If it doesn't exist, we treat this as a no-op rather than an error
      # so that vhs_mode.sh can use restore_vhs_env.sh opportunistically.
      SRC_DIR="${SLOTS_ROOT}/${ARG}"
      if [ ! -d "$SRC_DIR" ]; then
        echo "NOTE: Optional slot 'game' not found at ${SRC_DIR}. Nothing to restore." >&2
        exit 0
      fi
      ;;
    *)
      if [ -d "${ARG}" ]; then
        SRC_DIR="${ARG}"
      else
        die "Argument not recognized as slot or directory: ${ARG}"
      fi
      ;;
  esac
fi

echo
echo "Restoring from: ${SRC_DIR}"
echo

ensure_not_running "OBS Studio" "obs"
ensure_not_running "HandBrake" "ghb"  # Flatpak UI process name is typically 'ghb'

# Layout differences:
# - Slot snapshots store:        <slot>/obs-studio and <slot>/fr.handbrake.ghb
# - Timestamp backups store:     <ts>/obs-studio  and <ts>/fr.handbrake.ghb

OBS_SRC=""
HB_SRC=""

if [ -d "${SRC_DIR}/obs-studio" ]; then
  OBS_SRC="${SRC_DIR}/obs-studio"
fi

if [ -d "${SRC_DIR}/fr.handbrake.ghb" ]; then
  HB_SRC="${SRC_DIR}/fr.handbrake.ghb"
fi

# Restore
if [ -n "${OBS_SRC}" ]; then
  echo "Restoring OBS Studio..."
  restore_tree "${OBS_SRC}" "${OBS_DST}" "OBS config"
else
  echo "OBS backup not found in ${SRC_DIR} (skipping OBS restore)."
fi

echo

if [ -n "${HB_SRC}" ]; then
  echo "Restoring HandBrake (Flatpak)..."
  restore_tree "${HB_SRC}" "${HB_DST}" "HandBrake config"
else
  echo "HandBrake backup not found in ${SRC_DIR} (skipping HandBrake restore)."
fi

echo
echo "Restore complete."
echo "If OBS/HandBrake were open, launch them now and verify the active profile/presets."
