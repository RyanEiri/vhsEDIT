#!/usr/bin/env bash
# plex_cleanup.sh — Safely delete Plex media items listed in a file.
# Dry-run by default. Requires --confirm to actually delete.
# Logs to ./logs/plex_cleanup_<timestamp>.log
#
# Usage:
#   ./plex_cleanup.sh <deletion-list.txt>            # dry-run (safe preview)
#   ./plex_cleanup.sh --confirm <deletion-list.txt>  # live deletion
#
# deletion-list.txt format:
#   One path per line (file or directory).
#   Lines starting with # are treated as comments and ignored.
#
# Safety:
#   - Only paths under /mnt/media/ are permitted.
#   - Paths must be at least 3 levels deep (e.g. /mnt/media/movies/Drive/Title)
#     to prevent accidentally deleting a drive root or category directory.
#   - Requires typing 'DELETE' interactively before anything is removed.
set -euo pipefail

ALLOWED_PREFIX="/mnt/media"
MIN_DEPTH=3   # /mnt/media / <category> / <drive> / <title>  → need 3 slashes past prefix

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG="$LOG_DIR/plex_cleanup_${TIMESTAMP}.log"

CONFIRM=0
LIST_FILE=""

usage() {
    echo "Usage: $(basename "$0") [--confirm] <deletion-list.txt>"
    echo
    echo "  --confirm          Actually delete (default: dry-run, nothing is deleted)."
    echo "  deletion-list.txt  One path per line. Lines starting with # are skipped."
    echo
    echo "Safety: only paths under $ALLOWED_PREFIX at depth >=$MIN_DEPTH are allowed."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm) CONFIRM=1; shift ;;
        --help|-h) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *)  LIST_FILE="$1"; shift ;;
    esac
done

[[ -z "$LIST_FILE" ]] && usage
[[ ! -f "$LIST_FILE" ]] && { echo "ERROR: List file not found: $LIST_FILE"; exit 1; }

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "========================================"
echo "  Plex Cleanup"
echo "  $(date)"
if [[ $CONFIRM -eq 0 ]]; then
    echo "  MODE: DRY RUN — nothing will be deleted"
else
    echo "  MODE: LIVE — files WILL be permanently deleted"
fi
echo "  List: $LIST_FILE"
echo "  Log:  $LOG"
echo "========================================"
echo

# --- Read and validate paths ---
declare -a valid_paths=()
skipped=0

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue

    # Safety: must be under ALLOWED_PREFIX
    if [[ "$line" != "$ALLOWED_PREFIX"/* ]]; then
        echo "SKIP (outside $ALLOWED_PREFIX): $line"
        skipped=$((skipped+1))
        continue
    fi

    # Safety: must be deep enough — count slashes in relative path
    relative="${line#$ALLOWED_PREFIX/}"
    depth=$(( $(echo "$relative" | tr -cd '/' | wc -c) + 1 ))
    if [[ $depth -lt $MIN_DEPTH ]]; then
        echo "SKIP (too close to drive root — depth $depth < $MIN_DEPTH): $line"
        skipped=$((skipped+1))
        continue
    fi

    # Must exist
    if [[ ! -e "$line" ]]; then
        echo "SKIP (not found): $line"
        skipped=$((skipped+1))
        continue
    fi

    valid_paths+=("$line")
done < "$LIST_FILE"

echo "Valid paths:  ${#valid_paths[@]}"
[[ $skipped -gt 0 ]] && echo "Skipped:      $skipped"
echo

[[ ${#valid_paths[@]} -eq 0 ]] && { echo "Nothing to delete."; exit 0; }

# --- Show what will be deleted ---
echo "--- Items queued for deletion ---"
for path in "${valid_paths[@]}"; do
    size_h=$(du -sh "$path" 2>/dev/null | cut -f1 || echo "?")
    printf '  %-8s  %s\n' "$size_h" "$path"
done
echo

if [[ $CONFIRM -eq 0 ]]; then
    echo "DRY RUN complete. No files were deleted."
    echo "Re-run with --confirm to actually delete."
    exit 0
fi

# --- Interactive confirmation ---
echo "!!! WARNING: The above paths will be permanently deleted from NFS storage !!!"
read -r -p "Type 'DELETE' to confirm: " answer
if [[ "$answer" != "DELETE" ]]; then
    echo "Aborted."
    exit 1
fi

echo
echo "Deleting..."
deleted=0
errors=0

for path in "${valid_paths[@]}"; do
    size_h=$(du -sh "$path" 2>/dev/null | cut -f1 || echo "?")
    printf '[%s] %s\n  → ' "$size_h" "$path"

    if rm_out=$(rm -rf -- "$path" 2>&1); then
        echo "deleted"
        deleted=$((deleted+1))
    else
        echo "FAILED: $rm_out"
        errors=$((errors+1))
    fi
done

echo
echo "========================================"
echo "  Deleted: $deleted"
[[ $errors -gt 0 ]] && echo "  Errors:  $errors"
echo "  Log: $LOG"
echo "========================================"
