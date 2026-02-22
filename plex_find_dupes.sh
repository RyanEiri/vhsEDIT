#!/usr/bin/env bash
# plex_find_dupes.sh — Find potentially duplicate movies on Ironwolf8_1.
# Normalizes directory names to detect the same title with different encodings.
# Logs to ./logs/plex_dupes_<timestamp>.log
#
# Usage: ./plex_find_dupes.sh
# Env overrides: MOVIES_DIR, LOG_DIR
#
# NOTE: Normalization strips year info, so two films that share a base title
# (e.g. a remake and the original) will also be flagged. Review output carefully.
set -euo pipefail

MOVIES_DIR="${MOVIES_DIR:-/mnt/media/movies/Ironwolf8_1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG="$LOG_DIR/plex_dupes_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "========================================"
echo "  Plex Duplicate Movie Finder"
echo "  $(date)"
echo "  Scanning: $MOVIES_DIR"
echo "========================================"
echo

[[ ! -d "$MOVIES_DIR" ]] && { echo "ERROR: $MOVIES_DIR not accessible."; exit 1; }

normalize_title() {
    local name="$1"
    # Dots between word chars → spaces (torrent dot-separated naming)
    name=$(echo "$name" | sed -E 's/([a-zA-Z0-9])\.([a-zA-Z])/\1 \2/g')
    # Remove year in parens or brackets: (2007), [2007]
    name=$(echo "$name" | sed -E 's/[[(][0-9]{4}[])]//g')
    # Remove standalone year preceded by space
    name=$(echo "$name" | sed -E 's/ [12][0-9]{3}([ _.-]|$)/ /g')
    # Remove video quality tags
    name=$(echo "$name" | sed -Ei 's/\b(480p|576p|720p|1080p|2160p|4k|uhd|sd)\b/ /g')
    # Remove source tags
    name=$(echo "$name" | sed -Ei 's/\b(bluray|bdrip|brrip|dvdrip|dvdscr|dvd|webrip|web-dl|web|hdrip|hdtv|hddvd|vodrip|ts|cam|r5|scr)\b/ /g')
    # Remove codec tags
    name=$(echo "$name" | sed -Ei 's/\b(x264|x265|h264|h265|hevc|xvid|divx|avc|mpeg2|mpeg4|vp9|av1)\b/ /g')
    # Remove audio tags
    name=$(echo "$name" | sed -Ei 's/\b(aac|ac3|dts|mp3|dd5\.?1|5\.1|7\.1|6ch|2ch|dolby|atmos|truehd|flac|pcm)\b/ /g')
    # Remove misc release tags
    name=$(echo "$name" | sed -Ei 's/\b(limited|proper|unrated|extended|repack|retail|anniversary|internal|readnfo|remux|hdr|sdr|dv|imax|theatrical|directors?\.?cut|final\.?cut|redux)\b/ /g')
    # Remove trailing release group (dash followed by alphanumeric group name)
    name=$(echo "$name" | sed -E 's/ *- *[[:alnum:]]+ *$//')
    # Remove content in square brackets
    name=$(echo "$name" | sed -E 's/\[[^]]*\]/ /g')
    # Lowercase, collapse spaces, trim
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed 's/^ //;s/ $//')
    echo "$name"
}

# Build sorted "normalized_title TAB dir_path" list in a temp file
tmpfile=$(mktemp /tmp/plex_dupes_XXXXXX.tsv)
trap 'rm -f "$tmpfile"' EXIT

echo "Scanning movie directories..."
while IFS= read -r -d '' dir; do
    name=$(basename "$dir")
    [[ "$name" == .* ]] && continue
    norm=$(normalize_title "$name")
    [[ -z "$norm" ]] && continue
    printf '%s\t%s\n' "$norm" "$dir"
done < <(find "$MOVIES_DIR" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null) \
    | sort -t$'\t' -k1,1 > "$tmpfile"

total_movies=$(wc -l < "$tmpfile")
echo "Found $total_movies movie directories."
echo

# Walk sorted list and emit groups with >1 entry
found_any=0
prev_norm=""
prev_dir=""
in_group=0

while IFS=$'\t' read -r norm dir; do
    if [[ "$norm" == "$prev_norm" ]]; then
        if [[ $in_group -eq 0 ]]; then
            echo "--- Possible duplicate: '$norm' ---"
            size=$(du -sh "$prev_dir" 2>/dev/null | cut -f1)
            printf '  %-8s  %s\n' "$size" "$(basename "$prev_dir")"
            in_group=1
            found_any=1
        fi
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        printf '  %-8s  %s\n' "$size" "$(basename "$dir")"
    else
        [[ $in_group -eq 1 ]] && echo
        prev_norm="$norm"
        prev_dir="$dir"
        in_group=0
    fi
done < "$tmpfile"
[[ $in_group -eq 1 ]] && echo

if [[ $found_any -eq 0 ]]; then
    echo "No duplicate movies found."
else
    echo "Review the above. Add unwanted paths to a text file and run plex_cleanup.sh."
fi

echo
echo "========================================"
echo "  Done. Log: $LOG"
echo "========================================"
