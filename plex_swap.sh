#!/usr/bin/env bash
# plex_swap.sh — Delete original .mkv and rename .x264.mkv → .mkv in one step.
# Dry-run by default. Requires --confirm to actually execute.
# Logs to ./logs/plex_swap_<timestamp>.log
#
# Input list format: one original .mkv path per line (same format as plex_cleanup.sh).
# Lines starting with # are ignored.
#
# For each entry:
#   1. Verify original .mkv and corresponding .x264.mkv both exist
#   2. Delete original .mkv
#   3. Rename .x264.mkv → .mkv
#
# Safety:
#   - Only paths under /mnt/media/ are permitted.
#   - Paths must be at least 3 levels deep.
#   - Requires typing 'SWAP' interactively before anything is modified.
#   - Skips entries where either file is missing (won't half-execute).
#
# Usage:
#   ./plex_swap.sh <list.txt>            # dry-run
#   ./plex_swap.sh --confirm <list.txt>  # live swap
set -euo pipefail

ALLOWED_PREFIX="/mnt/media"
MIN_DEPTH=3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG="$LOG_DIR/plex_swap_${TIMESTAMP}.log"

CONFIRM=0
LIST_FILE=""

usage() {
    echo "Usage: $(basename "$0") [--confirm] <list.txt>"
    echo
    echo "  --confirm   Actually swap (default: dry-run, nothing is modified)."
    echo "  list.txt    One original .mkv path per line. Lines starting with # are skipped."
    echo
    echo "Safety: only paths under $ALLOWED_PREFIX at depth >=$MIN_DEPTH are allowed."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm) CONFIRM=1; shift ;;
        --help|-h) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) LIST_FILE="$1"; shift ;;
    esac
done

[[ -z "$LIST_FILE" ]] && usage
[[ ! -f "$LIST_FILE" ]] && { echo "ERROR: List file not found: $LIST_FILE"; exit 1; }

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "========================================"
echo "  Plex Swap (.x264.mkv → .mkv)"
echo "  $(date)"
if [[ $CONFIRM -eq 0 ]]; then
    echo "  MODE: DRY RUN — nothing will be modified"
else
    echo "  MODE: LIVE — files WILL be deleted and renamed"
fi
echo "  List: $LIST_FILE"
echo "  Log:  $LOG"
echo "========================================"
echo

declare -a valid_orig=()
declare -a valid_x264=()
skipped=0

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue

    # Must end in .mkv
    if [[ "$line" != *.mkv ]]; then
        echo "SKIP (not a .mkv path): $line"
        skipped=$((skipped+1))
        continue
    fi

    # Safety: must be under ALLOWED_PREFIX
    if [[ "$line" != "$ALLOWED_PREFIX"/* ]]; then
        echo "SKIP (outside $ALLOWED_PREFIX): $line"
        skipped=$((skipped+1))
        continue
    fi

    # Safety: depth check
    relative="${line#$ALLOWED_PREFIX/}"
    depth=$(( $(echo "$relative" | tr -cd '/' | wc -c) + 1 ))
    if [[ $depth -lt $MIN_DEPTH ]]; then
        echo "SKIP (too shallow — depth $depth < $MIN_DEPTH): $line"
        skipped=$((skipped+1))
        continue
    fi

    # Derive .x264.mkv path
    dir=$(dirname "$line")
    base=$(basename "$line" .mkv)
    x264="${dir}/${base}.x264.mkv"

    # Both files must exist
    if [[ ! -f "$line" ]]; then
        echo "SKIP (original not found — already swapped?): $line"
        skipped=$((skipped+1))
        continue
    fi
    if [[ ! -f "$x264" ]]; then
        echo "SKIP (.x264.mkv not found): $x264"
        skipped=$((skipped+1))
        continue
    fi

    valid_orig+=("$line")
    valid_x264+=("$x264")
done < "$LIST_FILE"

echo "Valid swaps: ${#valid_orig[@]}"
[[ $skipped -gt 0 ]] && echo "Skipped:     $skipped"
echo

[[ ${#valid_orig[@]} -eq 0 ]] && { echo "Nothing to swap."; exit 0; }

echo "--- Swaps queued ---"
for i in "${!valid_orig[@]}"; do
    orig_size=$(du -sh "${valid_orig[$i]}" 2>/dev/null | cut -f1 || echo "?")
    new_size=$(du -sh "${valid_x264[$i]}" 2>/dev/null | cut -f1 || echo "?")
    printf '  DEL  %-8s  %s\n' "$orig_size" "${valid_orig[$i]}"
    printf '  REN  %-8s  %s\n' "$new_size"  "${valid_x264[$i]}"
    echo
done

if [[ $CONFIRM -eq 0 ]]; then
    echo "DRY RUN complete. No files were modified."
    echo "Re-run with --confirm to actually swap."
    exit 0
fi

echo "!!! WARNING: Originals will be permanently deleted and encodes renamed on NFS !!!"
read -r -p "Type 'SWAP' to confirm: " answer
if [[ "$answer" != "SWAP" ]]; then
    echo "Aborted."
    exit 1
fi

echo
echo "Swapping..."
swapped=0
errors=0

for i in "${!valid_orig[@]}"; do
    orig="${valid_orig[$i]}"
    x264="${valid_x264[$i]}"
    printf '[%d/%d] %s\n' "$((i+1))" "${#valid_orig[@]}" "$(basename "$orig")"

    if rm -- "$orig" && mv -- "$x264" "$orig"; then
        echo "  ✓ done"
        swapped=$((swapped+1))
    else
        echo "  FAILED"
        errors=$((errors+1))
    fi
done

echo
echo "========================================"
echo "  Swapped: $swapped"
[[ $errors -gt 0 ]] && echo "  Errors:  $errors"
echo "  Log: $LOG"
echo "========================================"
