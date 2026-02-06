# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

An archival-first VHS digitization pipeline. Bash scripts capture VHS tapes via hardware (V4L2/ALSA), process them through denoising and deinterlacing, and produce lossless masters and lossy viewer derivatives. Editing is done in Kdenlive; the scripts handle everything before and after.

## Codec Policy (Strict — Do Not Violate)

- **Archival/intermediates:** FFV1 video + PCM (pcm_s16le) audio in MKV. No exceptions.
- **Viewer/Plex derivatives:** H.264 video + AAC audio in MKV. These are disposable.
- No ProRes. No HandBrake in the master pipeline.

## Architecture

### Pipeline Flow

```
Hardware (V4L2 + ALSA)
  → vhs_capture_ffmpeg.sh        (FFV1/PCM raw capture)
    → vhs_stabilize.sh → denoise.sh  (audio denoise, video bit-exact copy)
      → QTGMC via vspipe + ffmpeg     (deinterlace to progressive)
        → Kdenlive editing
          → vhs_viewer_encode.sh       (H.264/AAC for Plex)
          → vhs_upscale.sh             (AI upscale via Real-ESRGAN)
```

### Script Delegation Chain

`vhs_edit_prep_pipeline.sh` is the normal entry point. It calls:
1. `vhs_mode.sh archival` — switches OBS/HandBrake/ffmpeg config to archival slot
2. `vhs_capture_ffmpeg.sh` — captures raw VHS to `captures/archival/`
3. `vhs_stabilize.sh` — wrapper that delegates to `denoise.sh` for audio cleanup
4. Inline QTGMC step — uses `vspipe` piping `vhs-env/tools/qtgmc.vpy` into ffmpeg

The B&W variant (`vhs_bw_edit_prep_pipeline.sh`) adds a grayscale step after QTGMC.
The OBS variant (`vhs_obs_edit_prep_pipeline.sh`) skips capture and starts from an existing OBS recording.
`vhs_process.sh` is the re-processing entry point — takes an existing archival/stabilized MKV, re-runs stabilize and/or QTGMC without recapture, and hands off to Kdenlive.

### Key Design Patterns

- **All scripts use `set -euo pipefail`** and expect the same from new scripts.
- **Ctrl+C (exit 130) during capture is treated as a normal stop**, not a failure — the pipeline continues if an output file exists.
- **Environment variables override everything.** Every tunable parameter has an env default. Positional args override env where accepted.
- **Capture files are auto-renamed to `seg###.mkv`** (monotonic, never overwrites) in the archival directory.
- **ffmpeg binary selection:** Scripts prefer `/usr/local/bin/ffmpeg` (DeckLink-capable build), falling back to PATH. The `ffmpeg-current` symlink points to the active slot's `ffmpeg/` directory.
- **QTGMC runs via VapourSynth.** The `vhs-env/tools/qtgmc.vpy` script reads config from env vars (`VS_INPUT`, `VS_TFF`, `VS_FPSDIV`, `VS_PRESET`). It pipes Y4M through vspipe into ffmpeg.
- **VapourSynth plugins are explicitly loaded** in `qtgmc.vpy` (autoload is unreliable). Plugin path: `~/.local/share/vsrepo/plugins/`.

### Restore Safety

`restore_vhs_env.sh` refuses to run if OBS or HandBrake are currently open (checks via `pgrep`). Before overwriting, it moves the existing config aside as `.PRE-RESTORE.<timestamp>`.

### Environment Slots (`vhs-env/`)

Three configuration slots: `archival`, `viewer`, `game`. Each contains OBS Studio config, HandBrake config, and an `ffmpeg/capture.env` file defining hardware and codec settings. `vhs_mode.sh` switches between them; `backup_vhs_env.sh` and `restore_vhs_env.sh` manage snapshots.

### Capture Hardware

Defined in `vhs-env/archival/ffmpeg/capture.env`:
- Video: USB capture device via V4L2, 720x480 YUYV422 @ 30fps
- Audio: ALSA `hw:CARD=MS210x,DEV=0`, 48kHz stereo
- Color: SMPTE 170M (NTSC), TV range

### Upscale Pipeline (`vhs_upscale.sh`)

Chunked and resumable. Per-segment: extract JPEG frames → Real-ESRGAN 4x → downscale to 2x → H.264 encode. Segments stored as checkpoints in `vhs_upscale_work/<stem>/segments/`. A config fingerprint prevents mixing segments from different settings (override with `ALLOW_MIXED=1`).

## Key Directories

- `captures/archival/` — immutable raw captures (never modify)
- `captures/stabilized/` — denoised/QTGMC intermediates
- `captures/viewer/` — disposable Plex derivatives
- `vhs-env/{archival,viewer,game}/` — OBS/HandBrake/ffmpeg config slots
- `backups/` — timestamped config backups
- `logs/` — per-run logs for capture, stabilize, idet, QTGMC steps

## Dependencies

- ffmpeg (with FFV1 encoder), ffprobe, sox
- VapourSynth: vspipe, havsfunc (QTGMC), ffms2, mvtools, fmtconv, nnedi3, miscfilters
- Real-ESRGAN: `realesrgan-ncnn-vulkan` (Vulkan GPU), models in `~/opt/realesrgan-ncnn/models`
- OBS Studio, Kdenlive

## Philosophy

- **Capture once** — raw archival masters are ground truth and should never be modified.
- **Process many times** — denoise, QTGMC, and viewer encodes are repeatable from the archival master.
- **Never destroy information** — all intermediates are lossless; viewer files are disposable.
- **Masters are forever, viewer files are temporary.**

## When Modifying Scripts

- Preserve the FFV1+PCM codec policy for any new archival/intermediate outputs.
- Use `/usr/bin/ffmpeg` as the default `FFMPEG_BIN` (except capture scripts which prefer `/usr/local/bin/ffmpeg`).
- Keep scripts composable — each script should be runnable standalone and as part of a pipeline.
- Audio timestamp rebasing (`aresample=async=..., asetpts=N/SR/TB`) is critical for A/V sync; don't remove it without understanding the drift implications.
- The `vhs_stabilize.sh` → `denoise.sh` delegation is intentional: `denoise.sh` handles the actual SoX/ffmpeg work, `vhs_stabilize.sh` adds preset logic and default paths.
