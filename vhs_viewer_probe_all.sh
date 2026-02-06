#!/usr/bin/env bash
# vhs_viewer_probe_all.sh
set -euo pipefail

VIEWER_DIR="${HOME}/Videos/captures/viewer"
OUT_ROOT="${VIEWER_DIR}/_probe_reports"

FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"

mkdir -p "$OUT_ROOT"

index_tsv="${OUT_ROOT}/index.tsv"
printf "file\tcontainer\tvcodec\twidth\theight\tSAR\tDAR\tfield_order\tfps\tpix_fmt\tacodec\tchannels\tsample_rate\tduration_s\tbitrate_bps\tencoder\n" > "$index_tsv"

# Find only files directly under viewer/ (maxdepth 1), match by extension.
while IFS= read -r -d '' f; do
  # Relative file name (matches your TSV header "file")
  rel="$(basename "$f")"
  stem="${rel%.*}"

  out_dir="${OUT_ROOT}/${stem}"
  mkdir -p "$out_dir"

  printf "%s\n" "$f" > "${out_dir}/00_path.txt"

  # Full detail
  "$FFPROBE_BIN" -hide_banner -v error -i "$f" \
    -show_format -show_streams \
    > "${out_dir}/10_ffprobe_show_streams_format.txt" || true

  # JSON profile
  "$FFPROBE_BIN" -hide_banner -v error \
    -show_entries \
format=filename,format_name,duration,size,bit_rate,tags \
    -show_entries \
stream=index,codec_type,codec_name,profile,pix_fmt,width,height,sample_aspect_ratio,display_aspect_ratio,r_frame_rate,avg_frame_rate,field_order,color_range,color_space,color_primaries,color_transfer,time_base,bit_rate,nb_frames,tags \
    -of json \
    "$f" > "${out_dir}/20_ffprobe_profile.json" || true

  # Key summaries
  "$FFPROBE_BIN" -hide_banner -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,sample_aspect_ratio,display_aspect_ratio,field_order,avg_frame_rate,pix_fmt,bit_rate \
    -of default=nk=1:nw=1 \
    "$f" > "${out_dir}/30_key_video.txt" || true

  "$FFPROBE_BIN" -hide_banner -v error -select_streams a:0 \
    -show_entries stream=codec_name,channels,sample_rate,bit_rate \
    -of default=nk=1:nw=1 \
    "$f" > "${out_dir}/31_key_audio.txt" || true

  # TSV fields (queried directly)
  container="$("$FFPROBE_BIN" -v error -show_entries format=format_name -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  duration="$("$FFPROBE_BIN" -v error -show_entries format=duration -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  bitrate="$("$FFPROBE_BIN" -v error -show_entries format=bit_rate -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  encoder="$("$FFPROBE_BIN" -v error -show_entries format_tags=ENCODER -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"

  vcodec="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=codec_name -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  width="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=width -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  height="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=height -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  sar="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  dar="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  field_order="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=field_order -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  fps="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  pix_fmt="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"

  acodec="$("$FFPROBE_BIN" -v error -select_streams a:0 -show_entries stream=codec_name -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  ach="$("$FFPROBE_BIN" -v error -select_streams a:0 -show_entries stream=channels -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"
  asr="$("$FFPROBE_BIN" -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nk=1:nw=1 "$f" 2>/dev/null || true)"

  # Normalize empties
  for var in container duration bitrate encoder vcodec width height sar dar field_order fps pix_fmt acodec ach asr; do
    [[ -n "${!var:-}" ]] || printf -v "$var" "%s" "-"
  done

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$rel" "$container" "$vcodec" "$width" "$height" "$sar" "$dar" "$field_order" "$fps" "$pix_fmt" \
    "$acodec" "$ach" "$asr" "$duration" "$bitrate" "$encoder" \
    >> "$index_tsv"

done < <(
  find "$VIEWER_DIR" -maxdepth 1 -type f \
    \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.avi" -o -iname "*.ts" -o -iname "*.mts" -o -iname "*.m2ts" -o -iname "*.webm" -o -iname "*.mpg" -o -iname "*.mpeg" \) \
    -print0 | sort -z
)

echo "Done."
echo "Reports: $OUT_ROOT"
echo "Index:   $index_tsv"

