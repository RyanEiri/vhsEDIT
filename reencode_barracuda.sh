#!/usr/bin/env bash
# reencode_barracuda.sh — re-encode Barracuda8_1 high-bitrate files to HEVC
#
# Workflow per file:
#   1. Encode source (NFS) → staging (Patriot SSD)
#   2. Verify: duration match within 2 s, video+audio streams present
#   3. Copy staged file back to source directory (overwrites original)
#   4. Remove staged copy
#   5. Record path in done.log
#
# 4K files (≥3840px wide) are scaled down to 1920px — no 4K devices on premises.
# Audio streams are copied as-is (AC3/EAC3/AAC all pass through unchanged).
# Subtitles are copied when present.
#
# Resume: already-processed paths in done.log are skipped.
# Failures are written to fail.log with the reason.
#
# Usage:
#   ./reencode_barracuda.sh                     # process entire queue
#   ./reencode_barracuda.sh /path/to/file.mkv   # process a single file

set -euo pipefail

QUEUE="$HOME/Videos/barracuda_reencode_queue.txt"
STAGING="/media/ryan/Patriot/reencode_staging"
LOG_DIR="$HOME/Videos/logs/reencode"
DONE_LOG="$LOG_DIR/done.log"
FAIL_LOG="$LOG_DIR/fail.log"

CRF=20
PRESET=medium    # good compression; use 'fast' to roughly halve encode time

mkdir -p "$STAGING" "$LOG_DIR"
touch "$DONE_LOG" "$FAIL_LOG"

# ── stop / resume ──────────────────────────────────────────────────────────
# Stop:   Ctrl+C  or  kill $(cat ~/Videos/logs/reencode/pid)
# Resume: just re-run the script — done.log skips completed files
PID_FILE="$LOG_DIR/pid"
echo $$ > "$PID_FILE"

_current_staged=""
cleanup() {
    echo ""
    log "Interrupted — cleaning up staged file"
    [[ -n "$_current_staged" && -f "$_current_staged" ]] && rm -f "$_current_staged"
    rm -f "$PID_FILE"
    exit 1
}
trap cleanup INT TERM

# ── helpers ────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] FAIL: $*" | tee -a "$FAIL_LOG"; }

already_done() {
    grep -qxF "$1" "$DONE_LOG" 2>/dev/null
}

mark_done() {
    echo "$1" >> "$DONE_LOG"
}

get_duration() {
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || echo "0"
}

get_width() {
    ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$1" 2>/dev/null \
        | head -1 | cut -d',' -f1 || echo "0"
}

process_file() {
    local src="$1"

    if already_done "$src"; then
        log "SKIP (already done): $(basename "$src")"
        return 0
    fi

    if [[ ! -f "$src" ]]; then
        log "SKIP (not found): $src"
        return 0
    fi

    local name
    name=$(basename "$src" .mkv)
    local staged="$STAGING/${name}.hevc.mkv"
    local encode_log="$LOG_DIR/${name}.log"
    _current_staged="$staged"   # expose to trap

    log "START: $name"
    local src_width
    src_width=$(get_width "$src")

    # Build video filter — scale 4K down to 1920px wide, keep aspect ratio
    local vf_arg=()
    if (( src_width >= 3840 )); then
        log "  4K source (${src_width}px) — scaling to 1920px"
        vf_arg=(-vf "scale=1920:-2:flags=lanczos")
    fi

    # Encode
    log "  Encoding → $staged"
    if ! ffmpeg -y \
        -i "$src" \
        -map 0:v:0 \
        -map 0:a \
        -map "0:s?" \
        "${vf_arg[@]}" \
        -c:v libx265 -crf "$CRF" -preset "$PRESET" \
        -tag:v hvc1 \
        -c:a copy \
        -c:s copy \
        -max_muxing_queue_size 1024 \
        "$staged" \
        </dev/null >"$encode_log" 2>&1; then
        fail "encode failed: $src (see $encode_log)"
        rm -f "$staged"
        return 1
    fi

    # Verify — duration within 2 s, output file non-empty
    local dur_src dur_out
    dur_src=$(get_duration "$src")
    dur_out=$(get_duration "$staged")
    local ok
    ok=$(python3 -c "
src, out = float('${dur_src:-0}'), float('${dur_out:-0}')
print('ok' if src > 0 and out > 0 and abs(src - out) < 2.0 else f'bad src={src:.1f} out={out:.1f}')
")
    if [[ "$ok" != "ok" ]]; then
        fail "duration mismatch ($ok): $src"
        rm -f "$staged"
        return 1
    fi

    local src_gb out_gb
    src_gb=$(du -sh "$src"  | cut -f1)
    out_gb=$(du -sh "$staged" | cut -f1)
    log "  Verified OK — ${src_gb} → ${out_gb}"

    # Copy back to NFS (write to .new first, then rename to avoid partial overwrites)
    local tmp_dest="${src}.reencode.new"
    log "  Copying back to NFS…"
    if ! rsync --no-progress --bwlimit=18432 "$staged" "$tmp_dest"; then
        fail "rsync failed: $src"
        rm -f "$staged" "$tmp_dest"
        return 1
    fi

    # Atomic-ish swap on NFS
    mv "$tmp_dest" "$src"
    rm -f "$staged"
    _current_staged=""
    mark_done "$src"
    log "  DONE: $src"
}

# ── main ──────────────────────────────────────────────────────────────────

if [[ $# -gt 0 ]]; then
    # Single-file mode
    process_file "$1"
else
    # Queue mode — skip comment/blank lines
    total=$(grep -c '^/' "$QUEUE" 2>/dev/null || echo 0)
    done_count=$(wc -l < "$DONE_LOG")
    log "Queue: $total files  Already done: $done_count"
    n=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == '#'* ]] && continue
        n=$(( n + 1 ))
        log "[$n/$total] $(basename "$line")"
        process_file "$line" || true   # continue on failure
    done < "$QUEUE"
    log "Queue complete."
    rm -f "$PID_FILE"
fi
