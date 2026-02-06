#!/usr/bin/env bash
set -euo pipefail

# Save current OBS + HandBrake (Flatpak) configuration into a named slot under ~/Videos,
# and also create a timestamped backup under ~/Videos/backups for audit/rollback.
#
# Slots are intended to be: archival, viewer
#
# Usage:
#   ./backup_vhs_env.sh archival
#   ./backup_vhs_env.sh viewer
#   ./backup_vhs_env.sh            # legacy: timestamped backup only

VIDEOS_ROOT="${HOME}/Videos"
BACKUP_ROOT="${VIDEOS_ROOT}/backups"
SLOTS_ROOT="${VIDEOS_ROOT}/vhs-env"

OBS_SRC="${HOME}/.config/obs-studio"
HB_SRC="${HOME}/.var/app/fr.handbrake.ghb"

DATE_STR="$(date +%Y-%m-%d_%H-%M-%S)"
SLOT="${1:-}"

mkdir -p "${BACKUP_ROOT}" "${SLOTS_ROOT}"

die() { echo "ERROR: $*" >&2; exit 1; }

copy_tree() {
  # copy_tree SRC DST
  local src="$1"
  local dst="$2"
  if [ ! -d "$src" ]; then
    echo "  - Not found (skipping): $src"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  # rsync gives stable behavior and can clean old files in slot snapshots.
  rsync -a --delete "$src/" "$dst/"
  echo "  - Saved: $dst"
}

echo

# Always create a timestamped backup (safe default)
TS_DEST="${BACKUP_ROOT}/vhs-env-${DATE_STR}${SLOT:+-${SLOT}}"
echo "Creating timestamped backup: ${TS_DEST}"
mkdir -p "${TS_DEST}"

echo "Backing up OBS from:"
echo "  ${OBS_SRC}"
if [ -d "${OBS_SRC}" ]; then
  cp -a "${OBS_SRC}" "${TS_DEST}/"
  echo "  - Saved: ${TS_DEST}/obs-studio"
else
  echo "  - OBS config not found (skipping)."
fi

echo "Backing up HandBrake (Flatpak) from:"
echo "  ${HB_SRC}"
if [ -d "${HB_SRC}" ]; then
  cp -a "${HB_SRC}" "${TS_DEST}/"
  echo "  - Saved: ${TS_DEST}/fr.handbrake.ghb"
else
  echo "  - HandBrake Flatpak config not found (skipping)."
fi

# If a slot is provided, also save/refresh the slot snapshot
if [ -n "${SLOT}" ]; then
  case "${SLOT}" in
    archival|viewer|game) ;;
    *)
      die "Unknown slot '${SLOT}'. Expected: archival | viewer"
      ;;
  esac

  SLOT_DEST="${SLOTS_ROOT}/${SLOT}"
  echo
  echo "Updating slot snapshot: ${SLOT_DEST}"
  mkdir -p "${SLOT_DEST}"

  echo "Saving OBS snapshot into slot..."
  copy_tree "${OBS_SRC}" "${SLOT_DEST}/obs-studio"

  echo "Saving HandBrake snapshot into slot..."
  copy_tree "${HB_SRC}" "${SLOT_DEST}/fr.handbrake.ghb"

  echo
  echo "Slot '${SLOT}' updated."
  echo "To switch to this configuration later, run:"
  echo "  ${VIDEOS_ROOT}/restore_vhs_env.sh ${SLOT}"
fi

echo
echo "Backup complete."
echo "Timestamped backup location: ${TS_DEST}"
