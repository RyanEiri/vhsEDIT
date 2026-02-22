#!/usr/bin/env bash
# plex_probe_large.sh — ffprobe the largest video files across Ironwolf8_1.
# Reports codec, bitrate, resolution, and duration to identify bloated/inefficient encodes.
# Logs to ./logs/plex_probe_<timestamp>.log
#
# Usage: ./plex_probe_large.sh
# Env overrides: MOVIES_DIR, TVSHOWS_DIR, TOP_N, FFPROBE_BIN, LOG_DIR
#
# ffprobe only reads container headers over NFS — it does NOT download whole files.
set -euo pipefail

MOVIES_DIR="${MOVIES_DIR:-/mnt/media/movies/Ironwolf8_1}"
TVSHOWS_DIR="${TVSHOWS_DIR:-/mnt/media/tvshows/Ironwolf8_1}"
TOP_N="${TOP_N:-25}"
FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG="$LOG_DIR/plex_probe_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

if ! command -v "$FFPROBE_BIN" &>/dev/null; then
    echo "ERROR: ffprobe not found (FFPROBE_BIN=$FFPROBE_BIN)"
    exit 1
fi

echo "========================================"
echo "  Plex Large File Probe — Ironwolf8_1"
echo "  $(date)"
echo "  Top $TOP_N largest video files"
echo "========================================"
echo

# Build list of directories to search
search_dirs=()
[[ -d "$MOVIES_DIR" ]]  && search_dirs+=("$MOVIES_DIR")
[[ -d "$TVSHOWS_DIR" ]] && search_dirs+=("$TVSHOWS_DIR")
[[ ${#search_dirs[@]} -eq 0 ]] && { echo "ERROR: No mounts accessible."; exit 1; }

echo "Finding largest video files..."
mapfile -t large_files < <(
    find "${search_dirs[@]}" \
        -type f \
        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.mov' \) \
        -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn \
    | head -n "$TOP_N" \
    | cut -f2-
)

echo "Probing ${#large_files[@]} files (this may take a moment over NFS)..."
echo

# Header
printf '%-9s  %-6s  %7s  %7s  %-9s  %s\n' \
    "Size" "Codec" "Kbps" "Dur" "Res" "File"
printf '%0.s-' {1..115}
echo

for file in "${large_files[@]}"; do
    size_h=$(du -sh "$file" 2>/dev/null | cut -f1 || echo "?")

    # ffprobe: video stream info + format-level bitrate/duration
    probe=$("$FFPROBE_BIN" -v quiet \
        -select_streams v:0 \
        -show_entries "stream=codec_name,width,height:format=bit_rate,duration" \
        -of default=noprint_wrappers=1 \
        "$file" 2>/dev/null || true)

    vcodec=$(echo "$probe" | grep '^codec_name=' | head -1 | cut -d= -f2- || echo "?")
    width=$(echo "$probe"   | grep '^width='      | head -1 | cut -d= -f2- || echo "?")
    height=$(echo "$probe"  | grep '^height='     | head -1 | cut -d= -f2- || echo "?")
    bitrate=$(echo "$probe" | grep '^bit_rate='   | head -1 | cut -d= -f2- || echo "")
    duration=$(echo "$probe"| grep '^duration='   | head -1 | cut -d= -f2- || echo "")

    # Format bitrate as Kbps
    if [[ "$bitrate" =~ ^[0-9]+$ ]]; then
        kbps=$(( bitrate / 1000 ))
    else
        kbps="N/A"
    fi

    # Format duration as H:MM
    if [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        dur_int=${duration%%.*}
        dur_h=$(( dur_int / 3600 ))
        dur_m=$(( (dur_int % 3600) / 60 ))
        dur_fmt="${dur_h}:$(printf '%02d' "$dur_m")"
    else
        dur_fmt="?"
    fi

    res="${width}x${height}"
    [[ "$width" == "?" || "$height" == "?" ]] && res="?"

    printf '%-9s  %-6s  %7s  %7s  %-9s  %s\n' \
        "$size_h" "${vcodec:-?}" "$kbps" "$dur_fmt" "$res" "$(basename "$file")"
done

echo
echo "Inefficient codecs to watch for: xvid, divx, mpeg4, mpeg2"
echo "High bitrate = large file for its runtime. Low bitrate may indicate SD source."
echo
echo "========================================"
echo "  Done. Log: $LOG"
echo "========================================"
