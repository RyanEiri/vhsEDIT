# VHS Digitization Pipeline

This repository / directory contains a **disciplined, archival‑first VHS digitization workflow**.
The pipeline is designed to:

- Preserve *bit‑exact* capture data
- Keep all intermediate masters **lossless (FFV1 + PCM)**
- Allow repeatable re‑processing (denoise, QTGMC) without recapture
- Produce clean, space‑efficient **viewer derivatives** for Plex

The scripts are intentionally small, single‑purpose, and composable.

---

## Directory Layout

```
~/Videos/
├── captures/
│   ├── archival/        # Raw captures (immutable)
│   ├── stabilized/      # Denoised / QTGMC intermediates
│   └── viewer/          # Plex‑ready derivatives
├── vhs-env/
│   ├── archival/        # OBS/HandBrake slot: archival capture
│   ├── viewer/          # OBS/HandBrake slot: viewer capture
│   └── game/            # OBS/HandBrake slot: game capture
├── backups/             # Timestamped config backups
├── vhs_capture_ffmpeg.sh
├── vhs_stabilize.sh
├── vhs_process.sh
├── vhs_edit_prep_pipeline.sh
├── vhs_bw_edit_prep_pipeline.sh
├── vhs_viewer_encode.sh
├── vhs_upscale.sh
├── vhs_upscale_bw.sh
├── vhs_upscale_anime.sh
├── vhs_anime_edit_prep_pipeline.sh
├── vhs_ivtc.sh
├── vhs_viewer_encode_bw_patched.sh
├── vhs_mode.sh
├── backup_vhs_env.sh
├── restore_vhs_env.sh
├── vhs_qtgmc.vpy
└── vhs-env/tools/ivtc.vpy
```

---

## Script Roles (Authoritative)

### 1. `vhs_capture_ffmpeg.sh`
**Capture only.**

- Captures VHS from hardware
- Writes **FFV1 + PCM** MKV files
- Output: `captures/archival/*.mkv`
- No denoise, no QTGMC, no editing

This is the *ground truth* source and should never be modified.

---

### 2. `vhs_stabilize.sh`
**Audio denoise primitive.**

- Removes VHS line hum / broadband noise
- Uses a short noise sample from the beginning of the tape
- Video is copied bit‑exact
- Audio rebuilt as PCM

**Input:** any MKV with PCM audio  
**Output:** `captures/stabilized/*_STABLE.mkv`

This script is safe to re‑run at any time.

---

### 3. `vhs_process.sh`
**Prep from an existing file (no capture).**

Pipeline:
1. Takes an existing MKV (archival or stabilized)
2. Runs `vhs_stabilize.sh` (unless skipped)
3. Runs **QTGMC** if needed or forced
4. Ensures **FFV1 + PCM** output only
5. Selects the correct edit input
6. Hands off to Kdenlive

This script is used when:
- Adjusting denoise parameters
- Re‑running QTGMC
- Preparing non‑captured source files

---

### 4. `vhs_edit_prep_pipeline.sh`
**Capture + prep convenience wrapper.**

Pipeline:
1. Runs `vhs_capture_ffmpeg.sh`
2. Identifies the newly captured file
3. Calls `vhs_process.sh` on it

This is the **normal entry point** for digitizing a new tape.

---

### 5. `vhs_viewer_encode.sh`
**Viewer derivative for Plex.**

- Reads: `captures/stabilized/EDIT_MASTER.mkv`
- Writes: `captures/viewer/EDIT_MASTER.viewer.mkv`
- H.264 video, AAC audio
- Default: **2‑pass ABR @ 2000 kb/s video, 160 kb/s audio**
- Target size: ~1–1.5 GB for a 2‑hour tape

This output is **disposable** and can be regenerated at any time.

---

### 6. `vhs_upscale.sh`
**AI upscaling via Real‑ESRGAN.**

- Chunked, resumable processing (default 30s segments)
- Uses `realesrgan-ncnn-vulkan` with Vulkan GPU acceleration
- Internal upscale at 4× then downscale to 2× final resolution
- Segment checkpoints allow resume after interruption
- Safety guard prevents mixing segments with different settings

**Input:** any video file
**Output:** upscaled H.264 + AAC (viewer‑quality)

Usage:
```bash
./vhs_upscale.sh INPUT OUTPUT [segment_seconds] [crf]
```

Key environment variables:
- `MODEL` — Real‑ESRGAN model (default: `realesrgan-x4plus`)
- `INTERNAL_SCALE` / `FINAL_SCALE` — scale factors (default: 4 / 2)
- `CRF` — H.264 quality (default: 21)
- `WORK_ROOT` — working directory for segments

---

### 7. `vhs_bw_edit_prep_pipeline.sh`
**Black‑and‑white capture + prep pipeline.**

Same workflow as `vhs_edit_prep_pipeline.sh`, plus grayscale conversion:

1. Switch to archival mode
2. Capture archival master (FFV1/PCM)
3. Stabilize (audio denoise)
4. QTGMC deinterlace (if needed)
5. **Create B&W edit master** (desaturate → FFV1/PCM)
6. Print Kdenlive command

**Output:** `captures/stabilized/*_STABLE[_QTGMC]_BW.mkv`

The grayscale filter (`hue=s=0`) removes color while preserving the archival FFV1 + PCM codec policy.

Key environment variables:
- `BW_FORCE=1` — overwrite existing B&W output
- `BW_FILTER` — custom filter (default: `hue=s=0`)

---

### 8. `vhs_anime_edit_prep_pipeline.sh`
**Animation/anime capture + IVTC pipeline.**

Same workflow as `vhs_edit_prep_pipeline.sh`, but replaces QTGMC deinterlacing with **inverse telecine (IVTC)** for animated content that was originally 24fps film telecined to 30fps NTSC:

1. Switch to archival mode
2. Capture archival master (FFV1/PCM)
3. Stabilize (audio denoise)
4. **IVTC** (vivtc VFM + VDecimate) — recovers original 24fps cadence
5. Print Kdenlive command

**Output:** `captures/stabilized/*_STABLE_IVTC.mkv`

Key environment variables:
- `VS_TFF` — field order (1=TFF default, 0=BFF)

---

### 9. `vhs_ivtc.sh`
**Standalone IVTC runner.**

Runs inverse telecine on an existing stabilized file (no capture, no denoise):

- Uses `vhs-env/tools/ivtc.vpy` (vivtc VFM + VDecimate)
- Output: **FFV1 + PCM** (archival codec policy)
- Converts 30fps telecined → 24fps progressive

**Input:** any `*_STABLE.mkv`
**Output:** `*_IVTC.mkv`

Usage:
```bash
./vhs_ivtc.sh INPUT_STABLE.mkv [OUTPUT_IVTC.mkv]
```

---

### 10. `vhs_upscale_bw.sh`
**Black‑and‑white AI upscaling via Real‑ESRGAN.**

Same chunked, resumable pipeline as `vhs_upscale.sh`, adapted for B&W content:

- Extracts frames as grayscale (stored as RGB JPG for Real‑ESRGAN compatibility)
- Upscales with neutral chroma preserved throughout
- Same resume/safety‑guard behavior as the color variant

**Input:** any B&W video file
**Output:** upscaled H.264 + AAC (viewer‑quality)

Usage:
```bash
./vhs_upscale_bw.sh INPUT OUTPUT [segment_seconds] [crf]
```

Additional environment variable:
- `BW_FILTER` — grayscale filter (default: `hue=s=0`)

---

### 11. `vhs_upscale_anime.sh`
**Animation/anime AI upscaling via Real‑ESRGAN.**

Same chunked, resumable pipeline as `vhs_upscale.sh`, using the `realesrgan-x4plus-anime` model which is trained on drawn/cel content (cartoons, anime, hand‑drawn material).

**Input:** any animation/anime video file
**Output:** upscaled H.264 + AAC (viewer‑quality)

Usage:
```bash
./vhs_upscale_anime.sh INPUT OUTPUT [segment_seconds] [crf]
```

Key difference from `vhs_upscale.sh`:
- `MODEL` defaults to `realesrgan-x4plus-anime` instead of `realesrgan-x4plus`

---

### 12. `vhs_viewer_encode_bw_patched.sh`
**B&W‑aware viewer derivative for Plex.**

Enhanced version of `vhs_viewer_encode.sh` with B&W support and auto mode detection:

- `BW=1` forces grayscale output via `hue=s=0` (or `BW_FILTER` override)
- Auto‑detects **SD** (≤576p → 2‑pass ABR @ 2000 kb/s, 640×480) vs **HD** (>576p → CRF encode)
- Optional deinterlace control (`DEINTERLACE=auto|on|off`)
- Upgraded audio: AAC 320 kb/s, twoloop coder, 20 kHz cutoff

Usage:
```bash
BW=1 ./vhs_viewer_encode_bw_patched.sh [INPUT [OUTPUT.mkv]]
```

Falls back to the newest `.mkv` in `captures/stabilized/` if no input is specified.

---

### 13. `vhs_mode.sh`
**Environment switcher.**

Switches the active OBS, HandBrake, and ffmpeg configuration to a named mode:

```bash
./vhs_mode.sh {archival|viewer|game} [--launch]
```

- **archival / viewer** — Restores the OBS + HandBrake slot via `restore_vhs_env.sh` and repoints `~/Videos/ffmpeg-current` to the slot's `capture.env`
- **game** — Restores the game OBS slot (if it exists) and optionally launches OBS with the configured game‑capture profile/collection (`--launch`)
- Archival mode also verifies the active ffmpeg has the FFV1 encoder

Key environment variables:
- `OBS_PROFILE_GAME` / `OBS_COLLECTION_GAME` — OBS profile and scene collection for game mode

---

### 14. `backup_vhs_env.sh`
**Save current OBS + HandBrake configuration.**

Creates a timestamped backup and optionally updates a named slot snapshot:

```bash
./backup_vhs_env.sh                # timestamped backup only
./backup_vhs_env.sh archival       # + update archival slot
./backup_vhs_env.sh viewer         # + update viewer slot
./backup_vhs_env.sh game           # + update game slot
```

- Backs up `~/.config/obs-studio` and `~/.var/app/fr.handbrake.ghb`
- Timestamped backups go to `~/Videos/backups/vhs-env-<timestamp>[-slot]/`
- Slot snapshots go to `~/Videos/vhs-env/<slot>/` (used by `restore_vhs_env.sh`)

---

### 15. `restore_vhs_env.sh`
**Restore OBS + HandBrake configuration.**

Restores from a named slot or a timestamped backup:

```bash
./restore_vhs_env.sh archival      # restore from slot
./restore_vhs_env.sh viewer
./restore_vhs_env.sh game
./restore_vhs_env.sh <path>        # restore from specific backup directory
./restore_vhs_env.sh               # restore from most recent backup
```

- Moves the current config aside (`.PRE-RESTORE.*`) before overwriting
- Refuses to run if OBS or HandBrake are currently open
- The `game` slot is treated as optional (no error if missing)

---

## Codec Policy (Strict)

### Archival & Intermediates
- Video: **FFV1**
- Audio: **PCM (pcm_s16le)**
- Container: **MKV**

### Viewer / Plex
- Video: **H.264**
- Audio: **AAC**
- Container: **MKV**
- Bitrate‑controlled (not archival)

No ProRes, no HandBrake in the master pipeline.

---

## Typical Workflows

### Digitize a New Tape (Color)
```bash
~/Videos/vhs_edit_prep_pipeline.sh
```

### Digitize a New Tape (Black & White)
```bash
~/Videos/vhs_bw_edit_prep_pipeline.sh
```

### Digitize a New Tape (Animation / Anime)
```bash
# IVTC recovers 24fps from telecined 30fps animation
~/Videos/vhs_anime_edit_prep_pipeline.sh

# Run IVTC standalone on an existing stabilized file
~/Videos/vhs_ivtc.sh ~/Videos/captures/stabilized/seg001_STABLE.mkv
```

### Re‑run Prep on an Existing Capture
```bash
~/Videos/vhs_process.sh ~/Videos/captures/archival/<file>.mkv
```

### Upscale a Video (2× with AI)
```bash
# Color
~/Videos/vhs_upscale.sh input.mkv output_upscaled.mp4

# Black & white
~/Videos/vhs_upscale_bw.sh input_bw.mkv output_upscaled_bw.mp4

# Animation / anime
~/Videos/vhs_upscale_anime.sh input_anime.mkv output_upscaled_anime.mp4
```

### Export Viewer Copy After Editing
```bash
# Color
~/Videos/vhs_viewer_encode.sh

# Black & white
BW=1 ~/Videos/vhs_viewer_encode_bw_patched.sh
```

### Switch OBS Environment
```bash
# Switch to archival capture settings
~/Videos/vhs_mode.sh archival

# Switch to game capture and launch OBS
~/Videos/vhs_mode.sh game --launch
```

### Save / Restore OBS Configuration
```bash
# Save current config to a slot
~/Videos/backup_vhs_env.sh game

# Restore a slot
~/Videos/restore_vhs_env.sh game
```

---

## Philosophy

- **Capture once**
- **Process many times**
- **Never destroy information**
- **Viewer files are temporary**
- **Masters are forever**

This structure mirrors professional broadcast and archival digitization practice and is intentionally conservative.

---

*Last updated: February 2026*
