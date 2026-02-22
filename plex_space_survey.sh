#!/usr/bin/env bash
# plex_space_survey.sh — Survey disk usage on Ironwolf8_1 NFS-mounted Plex library.
# Logs to ./logs/plex_survey_<timestamp>.log
#
# Usage: ./plex_space_survey.sh
# Env overrides: MOVIES_DIR, TVSHOWS_DIR, TOP_N, LOG_DIR
set -euo pipefail

MOVIES_DIR="${MOVIES_DIR:-/mnt/media/movies/Ironwolf8_1}"
TVSHOWS_DIR="${TVSHOWS_DIR:-/mnt/media/tvshows/Ironwolf8_1}"
TOP_N="${TOP_N:-30}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG="$LOG_DIR/plex_survey_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "========================================"
echo "  Plex Space Survey — Ironwolf8_1"
echo "  $(date)"
echo "  Log: $LOG"
echo "========================================"
echo

# Verify mounts are accessible
ok=0
for dir in "$MOVIES_DIR" "$TVSHOWS_DIR"; do
    if [[ -d "$dir" ]]; then
        ok=$((ok+1))
    else
        echo "WARNING: Not accessible: $dir"
    fi
done
[[ $ok -eq 0 ]] && { echo "ERROR: No mounts accessible."; exit 1; }
echo

# Disk usage for mount(s) — deduplicate if both dirs are on the same NFS mount
echo "=== Mount Disk Usage ==="
df -h "$MOVIES_DIR" "$TVSHOWS_DIR" 2>/dev/null | awk '!seen[$0]++'
echo

# --- Movies ---
if [[ -d "$MOVIES_DIR" ]]; then
    echo "=== Movies — Top $TOP_N by Size ==="
    find "$MOVIES_DIR" -maxdepth 1 -mindepth 1 -not -name '.*' -type d -print0 \
        | xargs -0 du -sh 2>/dev/null \
        | sort -rh \
        | head -n "$TOP_N" || true
    echo
    movie_count=$(find "$MOVIES_DIR" -maxdepth 1 -mindepth 1 -not -name '.*' -type d | wc -l)
    echo "Total movies: $movie_count titles"
    echo "Total size:   $(du -sh "$MOVIES_DIR" 2>/dev/null | cut -f1)"
    echo
fi

# --- TV Shows ---
if [[ -d "$TVSHOWS_DIR" ]]; then
    echo "=== TV Shows — Top $TOP_N by Size ==="
    find "$TVSHOWS_DIR" -maxdepth 1 -mindepth 1 -not -name '.*' -type d -print0 \
        | xargs -0 du -sh 2>/dev/null \
        | sort -rh \
        | head -n "$TOP_N" || true
    echo
    show_count=$(find "$TVSHOWS_DIR" -maxdepth 1 -mindepth 1 -not -name '.*' -type d | wc -l)
    echo "Total shows:  $show_count titles"
    echo "Total size:   $(du -sh "$TVSHOWS_DIR" 2>/dev/null | cut -f1)"
    echo
fi

echo "========================================"
echo "  Survey complete. Log: $LOG"
echo "========================================"
