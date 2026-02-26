#!/usr/bin/env bash
# plex_reencode.sh — Re-encode large Blu-ray rip/remux files to space-efficient H.264/AAC.
#
# Output format:
#   Video:   libx264 CRF 18, slow preset, max 1080p (4K sources downscaled)
#   Audio 1: AAC stereo (192k), default — source stream chosen by language preference
#   Audio 2: AAC 5.1 (640k)            — same source stream, if it has ≥6 channels
#   Subs:    copied, ordered by language preference
#
# Language preference (descending): Icelandic (isl), English (eng), then rest
#   Override: LANG_PREFS="isl eng fra" (space-separated ISO 639-2 codes)
#
# Workflow:
#   1. Encode to local NVMe staging dir (fast writes, safe from NFS drops)
#   2. Move finished file to NFS destination (same dir as source)
#   3. Original is preserved; delete manually after verifying in Plex
#
# Naming on NFS:
#   Source .m2ts → output .mkv          (no conflict, clean swap)
#   Source .mkv  → output .x264.mkv     (original kept; swap manually when ready)
#
# Usage:
#   ./plex_reencode.sh                       # uses plex_reencode_list.txt
#   ./plex_reencode.sh my_list.txt
#
# Resume: if NFS destination already exists, that file is skipped.
#         If a staging file exists from a prior run, the script halts for that
#         entry and tells you what to do (move or delete it).
#
# Env overrides: STAGING_BASE, CRF, PRESET, FFMPEG_BIN, LANG_PREFS, LOG_DIR
set -euo pipefail

STAGING_BASE="${STAGING_BASE:-/media/ryan/Patriot/Videos/plex_encode}"
LIST_FILE="${1:-$(dirname "$0")/plex_reencode_list.txt}"
CRF="${CRF:-18}"
PRESET="${PRESET:-slow}"
FFMPEG_BIN="${FFMPEG_BIN:-/usr/bin/ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-/usr/local/bin/ffprobe}"
LANG_PREFS="${LANG_PREFS:-isl is ice eng en swe sv}"   # ISO 639-2 + 639-1 aliases, descending priority
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOG="$LOG_DIR/plex_reencode_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR" "$STAGING_BASE"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ── Language selection helpers ─────────────────────────────────────────────────

# Select the best audio stream by language preference, then by channel count.
# Probes all audio streams in one pass: "rel_idx,channels,lang" per line.
# Selection priority:
#   1. Highest-channel stream among preferred-language matches (isl > eng > ...)
#   2. Highest-channel stream overall (fallback when no language match)
# Outputs two lines: stream_index and channel_count.
# Usage: read -r audio_src src_channels < <(best_audio_stream <file>)
best_audio_stream() {
    local source="$1"
    # Probe: "channels,language_tag" per audio stream, in order
    local raw
    raw=$("$FFPROBE_BIN" -v quiet -select_streams a \
        -show_entries "stream=channels:stream_tags=language" \
        -of csv=p=0 "$source" 2>/dev/null || true)

    # Build arrays: rel_idx → channels, rel_idx → lang
    # Stop at the first blank line — m2ts files with multiple Blu-ray programs
    # cause ffprobe to list streams twice (separated by a blank line); we only
    # want the first group so that relative indices match ffmpeg's a:N mapping.
    local -a ch_arr=() lang_arr=()
    local rel_idx=0
    while IFS=',' read -r ch lang; do
        [[ -z "$ch" ]] && break  # blank line = end of first program section
        [[ "$ch" =~ ^[0-9]+$ ]] || continue
        ch_arr+=("$ch")
        lang_arr+=("${lang,,}")
        rel_idx=$((rel_idx+1))
    done <<< "$raw"

    local best_idx=0 best_ch=0

    # Pass 1: try each preferred language, pick highest-channel match
    for pref in $LANG_PREFS; do
        local found_idx=-1 found_ch=0
        for i in "${!ch_arr[@]}"; do
            if [[ "${lang_arr[$i]}" == "$pref" ]] && [[ "${ch_arr[$i]}" -gt "$found_ch" ]]; then
                found_idx=$i
                found_ch=${ch_arr[$i]}
            fi
        done
        if [[ $found_idx -ge 0 ]]; then
            echo "$found_idx"
            echo "$found_ch"
            return
        fi
    done

    # Pass 2: no language match — pick highest-channel stream overall
    for i in "${!ch_arr[@]}"; do
        if [[ "${ch_arr[$i]}" -gt "$best_ch" ]]; then
            best_idx=$i
            best_ch=${ch_arr[$i]}
        fi
    done
    echo "$best_idx"
    echo "${best_ch:-2}"
}

# Return ordered global stream indices for subtitle streams:
# preferred languages first (in LANG_PREFS order), then the rest in original order.
# Usage: ordered_subtitle_indices <file>
# Outputs a newline-separated list of global stream indices, or nothing if no subs.
ordered_subtitle_indices() {
    local source="$1"
    # CSV output: "global_index,language_tag" per subtitle stream
    local raw
    raw=$("$FFPROBE_BIN" -v quiet -select_streams s \
        -show_entries "stream=index:stream_tags=language" \
        -of csv=p=0 "$source" 2>/dev/null || true)

    [[ -z "$raw" ]] && return

    declare -a preferred=()
    declare -A seen=()

    # Collect indices for each preferred language in order
    for pref in $LANG_PREFS; do
        while IFS=',' read -r idx lang; do
            [[ -z "$idx" ]] && continue
            if [[ "${lang,,}" == "$pref" ]] && [[ -z "${seen[$idx]+x}" ]]; then
                preferred+=("$idx")
                seen["$idx"]=1
            fi
        done <<< "$raw"
    done

    # Append remaining streams in original order
    while IFS=',' read -r idx lang; do
        [[ -z "$idx" ]] && continue
        if [[ -z "${seen[$idx]+x}" ]]; then
            preferred+=("$idx")
            seen["$idx"]=1
        fi
    done <<< "$raw"

    local i
    for i in "${preferred[@]+"${preferred[@]}"}"; do
        echo "$i"
    done
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "========================================"  | tee -a "$LOG"
echo "  Plex Re-encode — H.264 / AAC"           | tee -a "$LOG"
echo "  $(date)"                                 | tee -a "$LOG"
echo "  CRF: $CRF   Preset: $PRESET"            | tee -a "$LOG"
echo "  Lang prefs: $LANG_PREFS"                 | tee -a "$LOG"
echo "  Staging: $STAGING_BASE"                  | tee -a "$LOG"
echo "  Log: $LOG"                               | tee -a "$LOG"
echo "========================================"  | tee -a "$LOG"
echo

[[ ! -f "$LIST_FILE" ]] && { log "ERROR: list file not found: $LIST_FILE"; exit 1; }

# Read source file list
declare -a sources=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    if [[ ! -f "$line" ]]; then
        log "WARN: not found, skipping — $line"
        continue
    fi
    sources+=("$line")
done < "$LIST_FILE"

log "Files to encode: ${#sources[@]}"
echo

total=${#sources[@]}
index=0

for source in "${sources[@]}"; do
    index=$((index+1))
    src_dir=$(dirname "$source")
    src_base=$(basename "$source")
    src_ext="${src_base##*.}"
    src_noext="${src_base%.*}"
    dir_name=$(basename "$src_dir")

    log "[$index/$total] ── $src_base"
    log "  Source: $source"

    # ── Probe video ───────────────────────────────────────
    vinfo=$("$FFPROBE_BIN" -v quiet -select_streams v:0 \
        -show_entries "stream=width,height" \
        -of default=noprint_wrappers=1 "$source" 2>/dev/null || true)
    src_height=$(echo "$vinfo" | grep '^height=' | head -1 | cut -d= -f2 || echo "")
    src_height=${src_height:-0}
    [[ "$src_height" =~ ^[0-9]+$ ]] || src_height=0

    # Fallback: if ffprobe returned 0, parse ffmpeg's stream info header
    if [[ "$src_height" -eq 0 ]]; then
        ffmpeg_info=$("$FFMPEG_BIN" -hide_banner -i "$source" 2>&1 || true)
        # Video stream line contains e.g. "1920x1080" or "3840x2160 [SAR ...]"
        src_height=$(echo "$ffmpeg_info" \
            | grep ' Video:' \
            | grep -oP '\d+x\K\d+' | head -1 || echo "0")
        src_height=${src_height:-0}
        [[ "$src_height" =~ ^[0-9]+$ ]] || src_height=0
    fi

    # ── Select preferred audio stream ─────────────────────
    { read -r audio_src; read -r src_channels; } < <(best_audio_stream "$source")

    # Log what we selected
    audio_lang_raw=$("$FFPROBE_BIN" -v quiet -select_streams "a:${audio_src}" \
        -show_entries "stream_tags=language" \
        -of csv=p=0 "$source" 2>/dev/null | head -1 || echo "")
    audio_lang=${audio_lang_raw:-unknown}
    log "  Video: ${src_height}p"
    log "  Audio: stream a:${audio_src} (lang=${audio_lang}, ${src_channels}ch)"

    # ── Probe subtitles ───────────────────────────────────
    mapfile -t sub_indices < <(ordered_subtitle_indices "$source")
    sub_codec="copy"
    if [[ ${#sub_indices[@]} -gt 0 ]]; then
        # Build lang labels for logging; detect mov_text (can't be copied to MKV)
        sub_langs=()
        for si in "${sub_indices[@]}"; do
            sl=$("$FFPROBE_BIN" -v quiet -select_streams "$si" \
                -show_entries "stream_tags=language" \
                -of csv=p=0 "$source" 2>/dev/null | head -1 || echo "?")
            sub_langs+=("${sl:-?}")
            sc=$("$FFPROBE_BIN" -v quiet -select_streams "$si" \
                -show_entries "stream=codec_name" \
                -of csv=p=0 "$source" 2>/dev/null | head -1 || true)
            [[ "$sc" == "mov_text" ]] && sub_codec="subrip"
        done
        log "  Subtitles: ${#sub_indices[@]} streams, order: ${sub_langs[*]}${sub_codec:+ (codec: $sub_codec)}"
    else
        log "  Subtitles: none"
    fi

    # ── Determine output paths ────────────────────────────
    if [[ "$src_ext" == "mkv" ]]; then
        out_name="${src_noext}.x264.mkv"
    else
        out_name="${src_noext}.mkv"
    fi

    nfs_dest="$src_dir/$out_name"
    staging_dir="$STAGING_BASE/$dir_name"
    staging_file="$staging_dir/$out_name"
    ffmpeg_log="$LOG_DIR/plex_reencode_${TIMESTAMP}_${index}_ffmpeg.log"

    mkdir -p "$staging_dir"

    # ── Skip / resume checks ──────────────────────────────
    if [[ -f "$nfs_dest" ]]; then
        nfs_size=$(du -sh "$nfs_dest" 2>/dev/null | cut -f1 || echo "?")
        log "  SKIP — NFS destination already exists ($nfs_size): $nfs_dest"
        echo
        continue
    fi

    if [[ -f "$staging_file" ]]; then
        staged_size=$(du -sh "$staging_file" 2>/dev/null | cut -f1 || echo "?")
        log "  HALT — staging file exists from a prior run ($staged_size):"
        log "    $staging_file"
        log "  If the encode completed successfully, move it manually:"
        log "    mv \"$staging_file\" \"$nfs_dest\""
        log "  If the encode was interrupted, delete it and re-run:"
        log "    rm \"$staging_file\""
        echo
        continue
    fi

    # ── Build ffmpeg command ──────────────────────────────
    declare -a ff_args=()
    ff_args+=(-hide_banner -i "$source")

    # Video: x264, scale to 1080p if taller
    ff_args+=(-map 0:v:0 -c:v libx264 -crf "$CRF" -preset "$PRESET")
    if [[ "$src_height" -gt 1080 ]]; then
        ff_args+=(-vf "scale=-2:1080")
        log "  Scaling: ${src_height}p → 1080p"
    fi

    # Audio track 0: stereo, default — from preferred source stream
    ff_args+=(-map "0:a:${audio_src}")
    ff_args+=(-c:a:0 aac -ac:a:0 2 -b:a:0 192k)
    ff_args+=(-metadata:s:a:0 "title=Stereo")
    ff_args+=(-disposition:a:0 default)

    # Audio track 1: 5.1 — same source stream, only if it has ≥6 channels
    if [[ "$src_channels" -ge 6 ]]; then
        ff_args+=(-map "0:a:${audio_src}")
        ff_args+=(-c:a:1 aac -ac:a:1 6 -b:a:1 640k)
        ff_args+=(-metadata:s:a:1 "title=5.1 Surround")
        ff_args+=(-disposition:a:1 0)
        log "  Audio out: stereo (192k) + 5.1 (640k)"
    else
        log "  Audio out: stereo only (source has ${src_channels}ch)"
    fi

    # Subtitles: map each global index in preference order
    if [[ ${#sub_indices[@]} -gt 0 ]]; then
        for si in "${sub_indices[@]}"; do
            ff_args+=(-map "0:${si}")
        done
        ff_args+=(-c:s "$sub_codec")
    fi

    # Chapters and container metadata
    ff_args+=(-map_chapters 0 -map_metadata 0)

    # Output file
    ff_args+=("$staging_file")

    # ── Encode ────────────────────────────────────────────
    log "  Encoding → $staging_file"
    log "  ffmpeg log: $ffmpeg_log"
    log "  (monitor: tail -f $ffmpeg_log)"

    encode_ok=0
    if "${FFMPEG_BIN}" "${ff_args[@]}" 2> >(tee -a "$ffmpeg_log" >&2); then
        encode_ok=1
    fi

    if [[ $encode_ok -eq 1 ]]; then
        src_bytes=$(stat --format="%s" "$source" 2>/dev/null || echo 0)
        enc_bytes=$(stat --format="%s" "$staging_file" 2>/dev/null || echo 0)
        staged_size=$(du -sh "$staging_file" 2>/dev/null | cut -f1 || echo "?")
        src_size_h=$(du -sh "$source" 2>/dev/null | cut -f1 || echo "?")
        log "  Encode OK — staged: $staged_size  source: $src_size_h"
        if [[ "$enc_bytes" -ge "$src_bytes" ]]; then
            log "  DISCARD — encode ($staged_size) is not smaller than source ($src_size_h); keeping original"
            rm -f "$staging_file"
            rmdir "$staging_dir" 2>/dev/null || true
        else
            log "  Moving to NFS: $nfs_dest"
            mv -- "$staging_file" "$nfs_dest"
            rmdir "$staging_dir" 2>/dev/null || true
            nfs_size=$(du -sh "$nfs_dest" 2>/dev/null | cut -f1 || echo "?")
            log "  ✓ Done — NFS size: $nfs_size"
            if [[ "$src_ext" == "mkv" ]]; then
                log "  NOTE: original still at: $source"
                log "  After verifying in Plex, delete original and rename .x264.mkv → .mkv"
            else
                log "  NOTE: original .${src_ext} still at: $source (delete when satisfied)"
            fi
        fi
    else
        log "  ERROR: ffmpeg failed — see $ffmpeg_log"
        log "  Partial staging file left at: $staging_file (delete before re-running)"
    fi

    unset ff_args
    echo
done

log "All encodes complete."
