# VHS Digitization Pipeline

This repository / directory contains a **VHS digitization pipeline with archival intent**.
The pipeline is designed to:

- Preserve *bit‑exact* capture data
- Produce lossless masters **(FFV1 + PCM)** and retain them when storage permits
- Allow repeatable re‑processing (denoise, QTGMC) without recapture
- Produce clean, space‑efficient **viewer derivatives** for Plex

When storage is constrained, only the viewer/access copy is kept after editing. Scripts and codec policy are written to always produce a lossless master — whether it is retained afterward is a storage decision, not a pipeline one.

The scripts are intentionally small, single‑purpose, and composable.

---

## Directory Layout

```
~/Videos/
├── captures/
│   ├── archival/        # Raw captures (immutable)
│   ├── stabilized/      # Denoised / QTGMC intermediates
│   └── viewer/          # Plex‑ready derivatives
├── vhs-gui/             # Rust capture/playback GUI (egui + libmpv2)
├── vhs-env/
│   ├── archival/        # OBS/HandBrake slot: archival capture
│   ├── viewer/          # OBS/HandBrake slot: viewer capture
│   └── game/            # OBS/HandBrake slot: game capture
├── backups/             # Timestamped config backups
├── vhs_capture_ffmpeg.sh
├── vhs_denoise.sh
├── vhs_process.sh
├── vhs_edit_prep_pipeline.sh
├── vhs_bw_edit_prep_pipeline.sh
├── vhs_viewer_encode.sh
├── vhs_upscale.sh
├── vhs_upscale_bw.sh
├── vhs_upscale_anime.sh
├── vhs_anime_edit_prep_pipeline.sh
├── vhs_ivtc.sh
├── vhs_vdecimate.sh
├── vhs_field_align.sh
├── vhs_ivtc_decombed.sh
├── vhs_viewer_encode_bw_patched.sh
├── vhs_mode.sh
├── backup_vhs_env.sh
├── restore_vhs_env.sh
├── vhs_qtgmc.vpy
├── vhs-env/tools/ivtc.vpy
├── vhs-env/tools/ivtc_decombed.vpy
├── vhs-env/tools/field_align.vpy
└── vhs-env/tools/vdecimate.vpy
```

---

## Script Roles (Authoritative)

### 1. `vhs_capture_ffmpeg.sh`
**Capture only.**

- Captures VHS from hardware
- Writes **FFV1 + PCM** MKV files
- Output: `captures/archival/*.mkv`
- No denoise, no QTGMC, no editing
- **Hard duration cap** via ffmpeg `-t` to prevent runaway captures filling the drive

Key environment variables:
- `MAX_CAPTURE_DURATION` — auto-stop time (default: `04:00:00`, T-120 LP). Set `06:00:00` for a full EP tape.

This is the *ground truth* source and should never be modified.

---

### 2. `vhs_denoise.sh`
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
2. Runs `vhs_denoise.sh` (unless skipped)
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
- VHS mode default: **CRF 18 single-pass** — clean enough to use as an upscale source
- HD mode default: CRF 20
- Set `V_BK=2000k` and unset `V_CRF` to revert to 2-pass ABR (Plex-only, no upscale planned)

This output is **disposable** and can be regenerated at any time.

---

### 6. `vhs_upscale.sh`
**AI upscaling via Real‑ESRGAN.**

- Chunked, resumable processing (default 30s segments)
- Uses `realesrgan-ncnn-vulkan` (Vulkan, default) or `realesrgan-rocm` (ROCm/PyTorch, opt‑in)
- Internal upscale at 4× then downscale to 2× final resolution
- Segment checkpoints allow resume after interruption
- Safety guard prevents mixing segments with different settings or backends

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
- `CRUSH` — crush preset (see [Crush Presets](#crush-presets) below)
- `BRIGHTNESS` — brightness adjustment; accepts named levels (`none`=0, `low`=0.02, `medium`=0.05, `high`=0.095) or a raw float
- `PRE_VF` — explicit filter chain, overrides `CRUSH` if set. Use `PRE_VF=""` to disable all pre‑filtering.
- `UPSCALE_BACKEND` — `vulkan` (default) or `rocm`; `rocm` uses `~/bin/realesrgan-rocm` (PyTorch+ROCm, supports `realesrgan-x4plus` and `realesrgan-x4plus-anime`). ROCm defaults to `TILE_SIZE=0` (full‑frame batched inference).
- `BATCH_SIZE` — frames per GPU batch for ROCm backend (default: 8; use `2` for RealESRGAN x4plus on 16 GB — deep RRDB intermediates OOM above that)

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

> **Note:** IVTC is no longer the recommended animation workflow. Animation now uses the standard QTGMC pipeline (`vhs_process.sh`), with `vhs_vdecimate.sh` run after Kdenlive editing before upscaling. This script is retained as a utility for cases where IVTC is specifically needed.

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

### 10. `vhs_ivtc_decombed.sh`
**IVTC with selective QTGMC decombing for combed frames.**

Runs inverse telecine (VFM field matching) followed by selective QTGMC deinterlacing on frames that VFM couldn't cleanly field‑match. VDecimate then removes duplicate frames (30fps → 24fps).

- Uses `vhs-env/tools/ivtc_decombed.vpy`
- Output: **FFV1 + PCM** (archival codec policy)
- More aggressive than plain IVTC — handles per‑frame combing artifacts

**Note:** For best results on animation, prefer the IVTC → QTGMC → VDecimate pipeline (see Typical Workflows) which runs faster and produces cleaner output.

**Input:** any `*_STABLE.mkv`
**Output:** `*_IVTC_DECOMBED.mkv`

Usage:
```bash
./vhs_ivtc_decombed.sh INPUT_STABLE.mkv [OUTPUT_IVTC_DECOMBED.mkv]
```

Key environment variables:
- `VS_TFF` — field order (1=TFF default, 0=BFF)
- `VS_DECOMB_PRESET` — QTGMC preset for decombing (default: `Fast`)

---

### 11. `vhs_vdecimate.sh`
**Remove telecine duplicate frames (30fps → 24fps).**

Runs VapourSynth VDecimate on a progressive file to remove the duplicate frames introduced by the 3:2 pulldown telecine process. Required for any VHS tape sourced from 24fps film — both animation and commercial film releases.

- Uses `vhs-env/tools/vdecimate.vpy`
- Output: **FFV1 + PCM**, 24fps
- Run **after** QTGMC, before upscaling

**Input:** QTGMC-processed progressive MKV  
**Output:** `*_VD.mkv`

Usage:
```bash
./vhs_vdecimate.sh EDIT_MASTER.mkv EDIT_MASTER_VD.mkv
```

**Note:** QTGMC deinterlaces but does not remove telecine pulldown — VDecimate is always a separate required step for film-sourced content.

---

### 12. `vhs_field_align.sh`
**Correct interlaced field misalignment (horizontal stepping).**

VHS playback hardware can introduce a static horizontal offset between the two interlaced fields, producing a stair‑step pattern on vertical edges. This script corrects the misalignment by separating the fields, applying a sub‑pixel horizontal shift to one field via high‑quality resampling (Spline36), then re‑weaving.

- Uses `vhs-env/tools/field_align.vpy`
- Output: **FFV1 + PCM** (archival codec policy)
- Should be run **before** QTGMC or IVTC (on the interlaced denoised file)

**Input:** any `*_STABLE.mkv` (interlaced)
**Output:** `*_ALIGNED.mkv`

Usage:
```bash
# Default: shift bottom field 1.0px rightward
./vhs_field_align.sh INPUT_STABLE.mkv [OUTPUT_ALIGNED.mkv]

# Adjust shift amount (positive = right, negative = left)
VS_FIELD_SHIFT=1.5 ./vhs_field_align.sh INPUT_STABLE.mkv

# Shift top field instead
VS_FIELD_SHIFT=-0.5 VS_SHIFT_FIELD=top ./vhs_field_align.sh INPUT_STABLE.mkv
```

Key environment variables:
- `VS_FIELD_SHIFT` — pixels to shift (float, default: `1.0`). Typical VHS values: 0.5–3.0
- `VS_SHIFT_FIELD` — which field to shift: `top` or `bottom` (default: `bottom`)
- `VS_TFF` — field order (1=TFF default, 0=BFF)

**Tip:** Try a short clip with different `VS_FIELD_SHIFT` values to find the right offset for your deck. The offset is usually consistent across all tapes from the same VCR.

---

### 13. `vhs_upscale_bw.sh`
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

Additional environment variables:
- `CRUSH` — crush preset (see [Crush Presets](#crush-presets) below); all presets include `hue=s=0` for grayscale
- `BW_FILTER` — explicit filter chain, overrides `CRUSH` if set

---

### 14. `vhs_upscale_anime.sh`
**Animation/anime AI upscaling via Real‑ESRGAN.**

Same chunked, resumable pipeline as `vhs_upscale.sh`, using the `realesrgan-x4plus-anime` model which is trained on drawn/cel content (cartoons, anime, hand‑drawn material).

**Input:** any animation/anime video file (ideally 24fps progressive from IVTC → QTGMC → VDecimate)
**Output:** upscaled H.264 + AAC (viewer‑quality)

Usage:
```bash
./vhs_upscale_anime.sh INPUT OUTPUT [segment_seconds] [crf]
```

Key differences from `vhs_upscale.sh`:
- `MODEL` defaults to `realesrgan-x4plus-anime` instead of `realesrgan-x4plus`
- `CRUSH` defaults to `none` (hqdn3d only, no luma crush) — luma crush causes banding on flat-color cel art
- `BRIGHTNESS` defaults to `0` (no uplift) — override with named levels or raw float if needed
- `DECOMB=1` — optional per‑segment IVTC + QTGMC decombing before frame extraction (slow; prefer the IVTC → QTGMC → VDecimate workflow instead)

---

### 15. `vhs_viewer_encode_bw_patched.sh`
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

### 16. `vhs_mode.sh`
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

### 17. `backup_vhs_env.sh`
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

### 18. `restore_vhs_env.sh`
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

### 19. `vhs-gui/` — Capture & Playback GUI

A native Rust desktop application that wraps the full digitization pipeline — capture, processing, playback, and AI upscaling — in a single window. Intended as the primary interface for day-to-day tape digitization.

**Build:**
```bash
cd vhs-gui
cargo build          # debug
cargo build --release
```

**Launch:**
```bash
DISPLAY=:0 ./vhs-gui/target/debug/vhs-gui
```

**Stack:** `eframe` 0.34 (glow/OpenGL via Wayland/winit) + `egui` for UI; `libmpv2` render API for video (off-screen FBO, GLSL blit shader); `nix` for SIGINT/SIGSTOP/SIGCONT to process groups; `image` (JPEG decode) for upscale preview; `trash` for recoverable deletes.

**What it does:**

- **Monitor** — opens the V4L2 capture device directly in mpv for a live signal check before recording. The device is released cleanly once capture starts.
- **Start Capture** — spawns `vhs_capture_ffmpeg.sh`. The V4L2 device is released from mpv first (Releasing state, 1 s timeout), then ffmpeg starts. As soon as the archival FFV1 file appears on disk it is opened immediately in the embedded player. When mpv reaches the current write position (EOF on the growing file) it automatically reopens at `duration − 2 s` to keep the preview near the live position — this repeats on every EOF, creating a rolling near-live window.
- **Stop Capture** — sends SIGINT to the capture process group; exit 130 is treated as success.
- **Library panel** — five sections in display order: Viewer → Edit Master (VD) → Edit Master → Stabilized → Archival. Click any entry to open it in the player.
- **Pipeline actions** — per-section buttons launch Denoise, QTGMC, IVTC, VDecimate, Viewer Encode, and all upscale variants as background jobs. Only one job runs at a time; buttons are disabled while busy.
- **Upscale jobs** — always launched with `UPSCALE_BACKEND=rocm BATCH_SIZE=2`. Show dual progress bars: total (completed segments / total) and segment (upscaled frames / extracted frames, driven by counting files in `frames_up/` vs `frames/`). Buttons: **Pause** (SIGSTOP), **Resume** (SIGCONT), **Stop after Segment** (sends SIGINT at next segment boundary; bypassed if all segments are already done so the concat/mux phase completes), **Cancel** (immediate SIGINT). Work dir is deleted automatically after the output file is confirmed on disk.
- **Upscale preview** — while an upscale job runs the central panel shows a side-by-side comparison: "Original 720×480" (left) vs "Upscaled 4×" (right), updated every 4 seconds. Frames are matched by filename across `frames/` and `frames_up/`. A `request_repaint_after(1 s)` heartbeat keeps the loop alive when mpv is idle.
- **Rename** — Viewer files get a Rename… button that pre-fills an editable field with a human-readable title suggestion: `EDIT_MASTER-VHS_TRAILER-THE_GREAT_MOUSE_DETECTIVE_VD.upscale.mkv` → `VHS Trailer — The Great Mouse Detective.mkv`. Strips pipeline suffixes/prefixes, converts underscores to spaces, title-cases with acronym preservation (VHS, TV, BBC, DVD, etc.), formats with em dash.
- **Delete** — moves files to `~/.local/share/Trash/` (FreeDesktop.org spec) via the `trash` crate; recoverable from any file manager. Confirmation prompt reads "Move to Trash?".
- **Playback controls** — click-to-pause; time / remaining OSD; same mpv instance reused for all sources.

**Capture state machine:** `Idle → Monitoring → Releasing (1 s timeout) → Capturing`. V4L2 device is exclusive to ffmpeg during capture; mpv returns to idle during Releasing then switches to the growing archival file once capture begins.

**Application icon:** 256×256 RGBA VHS cassette embedded in the binary (`assets/icon.png`, decoded with the `png` crate).

**System dependency note:** Requires `libmpv2` runtime (installed via `dpkg --force-depends` due to libcaca PPA conflict; `libmpv-dev` headers are not needed after the build).

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
# Animation uses the standard QTGMC workflow — same as color
~/Videos/vhs_edit_prep_pipeline.sh
# or, to skip Kdenlive launch:
NO_LAUNCH=1 ~/Videos/vhs_process.sh VHS_ARCHIVAL_<timestamp>.mkv

# After Kdenlive editing, run VDecimate before upscaling (see Animation Upscale Pipeline)
```

### Animation Upscale Pipeline

Animation EDIT_MASTERs have already been through QTGMC at denoise+QTGMC time (`FORCE_QTGMC=1` default in `vhs_process.sh`). The post-edit upscale pipeline is two steps:

```bash
# 1. VDecimate — remove 3:2 pulldown duplicate frames (30fps → 24fps)
~/Videos/vhs_vdecimate.sh EDIT_MASTER-TITLE.mkv EDIT_MASTER-TITLE_VD.mkv

# 2. Upscale with anime model (ROCm backend, no luma crush)
UPSCALE_BACKEND=rocm BATCH_SIZE=2 \
  ~/Videos/vhs_upscale_anime.sh EDIT_MASTER-TITLE_VD.mkv \
    ~/Videos/captures/viewer/VHS\ Trailer\ —\ Title.mkv
```

**VDecimate is also required for commercial film VHS tapes** (live action films on VHS were telecined from 24fps just like animation). Run `vhs_vdecimate.sh` on the EDIT_MASTER before upscaling any film-sourced content. Native 30fps video (home video, TV news) does not need it.

### Backlog Workflow (Quick Capture, Upscale Later)

When working through a backlog of tapes, produce a viewer copy immediately and defer upscaling:

```bash
# 1. Capture → denoise + QTGMC as normal
NO_LAUNCH=1 ~/Videos/vhs_process.sh VHS_ARCHIVAL_<timestamp>.mkv

# 2. Produce viewer copy (CRF 18 — clean enough for later upscaling)
~/Videos/vhs_viewer_encode.sh EDIT_MASTER-TITLE.mkv
# → captures/viewer/EDIT_MASTER-TITLE.viewer.mkv  (Plex-ready immediately)

# 3. Later: upscale from viewer encode
~/Videos/vhs_upscale.sh captures/viewer/EDIT_MASTER-TITLE.viewer.mkv \
  captures/viewer/TITLE.upscale.mkv
```

### Fix Field Misalignment (Horizontal Stepping)
```bash
# Correct stepping before IVTC or QTGMC
VS_FIELD_SHIFT=1.5 ~/Videos/vhs_field_align.sh ~/Videos/captures/stabilized/seg001_STABLE.mkv

# Then run IVTC (animation) or QTGMC (live action) on the aligned file
~/Videos/vhs_ivtc.sh ~/Videos/captures/stabilized/seg001_STABLE_ALIGNED.mkv
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

### Naming Final YouTube / Viewer Files

Use an **em dash** (`—`) as the separator between the type prefix and the title:

```
VHS Trailer — Dances with Wolves.mkv
VHS Commercial — Disney World.mkv
VHS Commercials — Walt Disney Home Video.mkv
VHS Special Features — Fun and Fancy Free.mkv
```

Drop the `.upscale` pipeline suffix from the final filename. Hyphen-minus (`-`) is stripped by YouTube's upload sanitization; em dash survives. Internal pipeline files (EDIT_MASTERs, `_VD.mkv`, in-progress outputs) keep the all-caps underscore convention.

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

## Resumable Upscaling

AI upscaling is the slowest step in the pipeline — a single 80‑minute tape can take
hours of GPU time through Real‑ESRGAN. Most upscaling tools (including GUI applications
like chaiNNer) treat the entire job as a single atomic operation: if the process crashes,
the GPU driver resets, or you simply need to shut down, you lose all progress and start
from scratch.

The `vhs_upscale*.sh` scripts solve this with a **chunked, segment‑based checkpoint
system**:

1. The input video is split into short segments (default 30 seconds).
2. Each segment is fully processed (frame extraction → Real‑ESRGAN → H.264 encode)
   and written as an independent checkpoint file (`segments/seg_XXX.mp4`).
3. On the next run, any segment whose checkpoint file already exists is skipped.
4. After all segments complete, they are concatenated and the original audio is muxed in.

This means:
- **Interruption is free.** Kill the process at any time; completed segments are preserved.
- **Resume is automatic.** Re‑run the same command and it picks up where it left off.
- **Progress is visible.** Each segment logs independently, and you can count checkpoint
  files to gauge completion.

A **configuration fingerprint** (`run_config.txt`) is written alongside the segments.
If you change settings (model, CRF, scale factor, etc.) between runs, the script refuses
to continue rather than silently mixing segments from different configurations. Override
with `ALLOW_MIXED=1` if intentional.

---

## Crush Presets

All upscale scripts (`vhs_upscale.sh`, `vhs_upscale_bw.sh`, `vhs_upscale_anime.sh`) support a `CRUSH` environment variable that selects a pre‑filtering preset applied during frame extraction, before Real‑ESRGAN sees the frames. The filters denoise shadow noise and crush dark values so the upscaler doesn't hallucinate texture in noisy black regions.

**Default for all scripts: `CRUSH=none`** — hqdn3d denoising only, no luma remap, no brightness adjustment. Use `small`/`medium`/`heavy` only when a specific tape's noise floor needs correction.

| Preset | Threshold | Brightness default | Use case |
|--------|-----------|------------|----------|
| `none` **(default)** | — | 0 | hqdn3d only — no luma crush, no brightness uplift |
| `small` | 16 | 0 | Crushes below TV black level; tapes with noisy blacks |
| `medium` | 50 | 0.05 | Darker/noisier tapes needing moderate cleanup |
| `heavy` | 70 | 0.095 | Very noisy tapes, heavy shadow noise |

`BRIGHTNESS` accepts named levels: `none`=0, `low`=0.02, `medium`=0.05, `high`=0.095, or a raw float. Named levels override the preset default without changing the crush threshold.

All presets include `hqdn3d=3:2:4:3` denoise and a **ramped luma crush**: values below the threshold are zeroed, and the remaining range is smoothly remapped to 0–255 (no hard clipping). The B&W script additionally includes `hue=s=0` for grayscale conversion in every preset.

The `BRIGHTNESS` environment variable overrides the preset's default brightness without changing the crush level. This is useful for fine‑tuning per‑tape without building a full custom `PRE_VF`.

Usage:
```bash
# Default (no crush, no brightness — hqdn3d only)
~/Videos/vhs_upscale.sh input.mkv output.mkv

# Medium crush
CRUSH=medium ~/Videos/vhs_upscale_bw.sh input_bw.mkv output_bw.mkv

# Heavy crush with custom brightness override
CRUSH=heavy BRIGHTNESS=0.12 ~/Videos/vhs_upscale_anime.sh input_anime.mkv output_anime.mkv

# Small crush with brightness bump
BRIGHTNESS=0.08 ~/Videos/vhs_upscale.sh input.mkv output.mkv

# Fully custom (overrides CRUSH entirely)
PRE_VF="hqdn3d=3:2:4:3,lutyuv=y='if(lt(val,35),0,min(255,(val-35)*255/220))',eq=brightness=0.1" \
  ~/Videos/vhs_upscale.sh input.mkv output.mkv

# Disable all pre-filtering
PRE_VF="" ~/Videos/vhs_upscale.sh input.mkv output.mkv
```

---

## Process Group Management (PGID)

All pipeline scripts write a **process group ID** (PGID) file on startup and clean it up on exit. This enables reliable pause, resume, and stop of any running pipeline step from an external shell or automation tool.

| Script | PGID file |
|--------|-----------|
| `vhs_capture_ffmpeg.sh` | `logs/capture.pgid` |
| `vhs_qtgmc_only.sh` | `logs/qtgmc.pgid` |
| `vhs_ivtc.sh` | `logs/ivtc.pgid` |
| `vhs_ivtc_decombed.sh` | `logs/ivtc_decombed.pgid` |
| `vhs_field_align.sh` | `logs/field_align.pgid` |
| `vhs_upscale*.sh` | `<work_dir>/upscale.pgid` |

Usage:
```bash
# Pause a running capture
kill -STOP -$(cat ~/Videos/logs/capture.pgid)

# Resume
kill -CONT -$(cat ~/Videos/logs/capture.pgid)

# Gracefully stop
kill -INT -$(cat ~/Videos/logs/capture.pgid)
```

The negative PID in `kill` targets the entire process group, ensuring child processes (ffmpeg, vspipe, realesrgan) are also signaled.

---

## Blu‑ray Pipeline (Planned)

A Blu‑ray ripping and re‑encoding pipeline is planned to complement the VHS workflow, producing the same archival and viewer derivative structure.

**Hardware:** The Blu‑ray drive is physically installed on the Proxmox node `shakyamuni.buddha.lan` and is accessible from the `files.buddha.lan` VM. The drive is currently disconnected.

---

## Recommended Upscale Models

Model files are not included in this repository due to size. The table below lists every model used in production, where to obtain it, and which backend it requires.

### Real-ESRGAN — xinntao (ncnn + ROCm)

| Model | Scale | Get it from | Notes |
|---|---|---|---|
| `realesrgan-x4plus` | 4× | [xinntao/Real-ESRGAN releases](https://github.com/xinntao/Real-ESRGAN/releases) | General live-action VHS |
| `realesrgan-x4plus-anime` | 4× | [xinntao/Real-ESRGAN releases](https://github.com/xinntao/Real-ESRGAN/releases) | Animation and cel art |
| `realesrgan-x2plus` | 2× | [xinntao/Real-ESRGAN releases](https://github.com/xinntao/Real-ESRGAN/releases) | When 4× is too aggressive |

License: BSD 3-Clause. Both `.pth` (ROCm) and ncnn `.param`/`.bin` variants are on the releases page.

### Community VHS models — ROCm only (PyTorch `.pth`)

Sourced from [OpenModelDB](https://openmodeldb.info/). Verify each model's license on its OpenModelDB page before redistributing.

| Model | Scale | OpenModelDB | Notes |
|---|---|---|---|
| `2x_VHS-Film` | 2× | [2x VHS upscale and denoise Film](https://openmodeldb.info/models/2x-VHS-upscale-and-denoise-Film) | Live-action at 2× with integrated denoise |
| `ToonVHS-1x` | 1× | [ToonVHS 1x](https://openmodeldb.info/models/1x-ToonVHS) | Sharpen/denoise animation without resizing |
| `VHS-Sharpen-1x` | 1× | [VHS Sharpen 1x](https://openmodeldb.info/models/1x-VHS-Sharpen) | Sharpen/denoise live-action without resizing |

### Where to place models

**ROCm backend** (`.pth`): `~/opt/realesrgan-rocm/models/`. Each model also needs an entry in `MODEL_MAP` in `~/opt/realesrgan-rocm/driver.py`.

**Vulkan/ncnn backend** (`.param` + `.bin`): `~/opt/realesrgan-ncnn/models/`. `realesrgan-ncnn-vulkan` hardcodes its network architecture by matching the model name against `realesrgan-x4plus`, `realesrgan-x4plus-anime`, `realesrnet-x4plus`, or `realesr-animevideov3*` — any other name segfaults it, even with valid `.param`/`.bin` files present. The upscale scripts and vhs-gui only discover/offer names in that set for the Vulkan backend; the community VHS models below are ROCm-only regardless of what files exist in this directory.

### Choosing a model

| Scenario | Model | Int. Scale | Final Scale | Script |
|---|---|---|---|---|
| **Live-action VHS → 2× (default)** | `realesrgan-x2plus` | 2× | 2× | `vhs_upscale.sh` |
| Live-action → 2×, more aggressive | `realesrgan-x4plus` | 4× | 2× | `vhs_upscale.sh` |
| Live-action with warm style | `2x_VHS-Film` | 2× | 2× | `vhs_upscale.sh` (`UPSCALE_BACKEND=rocm`) |
| Animation after VDecimate | `realesrgan-x4plus-anime` | 4× | 2× | `vhs_upscale_anime.sh` |
| Animation, keep resolution | `ToonVHS-1x` | 1× | 1× | `vhs_upscale_anime.sh` (`UPSCALE_BACKEND=rocm`) |
| **B&W live-action → 2× (default)** | `realesrgan-x2plus` | 2× | 2× | `vhs_upscale_bw.sh` |
| Sharpen only, no resize | `VHS-Sharpen-1x` | 1× | 1× | `vhs_upscale.sh` (`UPSCALE_BACKEND=rocm`) |

`realesrgan-x2plus` is the preferred neutral model for 2× output. It runs faster than routing through `realesrgan-x4plus` at Int 4× / Final 2× and produces equivalent quality at the target resolution. Use `realesrgan-x4plus` when you want the extra sharpening headroom of a 4× internal pass.

`2x_VHS-Film` introduces a warm/amber color shift that is a model artifact, not source-accurate. Suitable when the master will be retained; avoid when the viewer copy may become the only surviving copy.

---

## Philosophy

- **Capture once** — raw archival masters are ground truth and should never be modified.
- **Process many times** — denoise, QTGMC, and viewer encodes are repeatable from the archival master.
- **Retain masters when storage allows** — the pipeline always produces a lossless master; whether it is kept afterward depends on available storage. When space is constrained, only the viewer copy is retained.
- **Viewer copies are processed for watchability** — deinterlacing, AI upscaling, luma conditioning, and brightness adjustment are applied to the access copy only. These are not part of the archival record.
- **Editing is cuts‑only** — no color grading, dropout repair, or image stabilization. VHS artifacts are preserved, not corrected.
- **Viewer files are disposable; masters are the goal.**

---

*Last updated: June 2026*
