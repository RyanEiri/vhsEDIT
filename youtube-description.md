**Technical note:** Viewer/access encode (640×480, 4:3 square pixel, progressive) from analog VHS. SD Rec.601 color, H.264/AAC, edited in Kdenlive and encoded with FFmpeg on Linux.

Captured from VHS using a Sony SLV-N500 VCR and a MacroSilicon MS210x USB capture device. Most tapes are captured via direct composite; unstable tapes are passed through a Toshiba DVD recorder for line stabilization. Edited in Kdenlive and encoded with FFmpeg on Linux.

---

**VHS Digitization – Direct Hardware Capture and Preservation-Focused Encoding**

This video is sourced directly from an original VHS tape using a dedicated analog playback and capture chain. The signal is captured in real time and processed using a custom FFmpeg-based workflow designed to preserve synchronization, signal structure, and the native characteristics of the VHS format.

---

**Capture & Encoding Information**

• **Source format:** Analog VHS (NTSC)  
• **Capture resolution:** 640×480, 4:3 (square pixel, SAR 1:1)  
• **Scan:** Progressive (deinterlaced for viewer access)  
• **Color:** SD Rec.601 / SMPTE 170M (TV range)  
• **Video encoding:** H.264 (libx264)  
• **Audio encoding:** AAC-LC, stereo, 48 kHz  
• **Editing:** Cuts and assembly only in Kdenlive  
• **Final encoding:** FFmpeg on Linux  

---

**Playback and Capture Hardware**

• **VCR:** Sony SLV-N500  
• **USB capture device:** MacroSilicon MS210x (EasyCAP-class USB video grabber)

---

**Signal Path**

**Primary ingest path**  
Direct composite video from the VCR to the USB capture device. This is the default path for this generation of captures and is used whenever the tape plays stably without timing errors.

**Conditional stabilization path (when required)**  
For tapes exhibiting timing instability or frame-sync issues, playback is routed through a Toshiba DVD recorder acting as a line-stabilizing passthrough. The recorder outputs either S-Video or composite to the capture device, selected based on luma stability and overall signal behavior. No recording is performed on the DVD recorder; it is used solely for signal conditioning.

---

**Ingest, Editing, and Processing**

• Real-time capture on Linux using FFmpeg  
• Uncompressed UVC video capture (720×480 NTSC, interlaced)  
• 48 kHz 16-bit PCM stereo audio captured alongside video  
• Editorial work limited to cuts and assembly performed in Kdenlive  
• Final encoding performed via FFmpeg  

---

**AI Upscale (when applicable)**

Some uploads have been AI-upscaled from their native SD resolution to produce a cleaner, higher-resolution viewer copy. The upscale process:

• **Model:** Real-ESRGAN (realesrgan-x4plus) via realesrgan-ncnn-vulkan
• **GPU:** AMD RX 7800 XT (Vulkan)
• **Process:** 4× internal upscale → downscale to 2× final (1280×960 from 720×480)
• **Output resolution:** 1280×960, 4:3 (DAR-correct)
• **Pre-processing:** Light denoise (hqdn3d) and luma crush applied before upscaling to prevent the model from hallucinating texture in dark/noisy regions. Default is a small crush (threshold 16, ramped to preserve highlight detail); medium and heavy presets are available for noisier or lower-contrast sources.
• **Output encoding:** H.264 (libx264), CRF 21
• **Animation variant:** Uses the realesrgan-x4plus-anime model for drawn/cel content

The upscale is performed on the edited Kdenlive export, not the raw capture. The original SD master is not currently retained.

---

**Animation Pipeline (when applicable)**

Animated content originally produced at 24fps film cadence is telecined to 30fps NTSC for VHS distribution. To recover the original frame rate and eliminate interlacing artifacts, animated uploads go through a dedicated processing chain before upscaling:

1. **IVTC (Inverse Telecine):** VapourSynth vivtc VFM field-matches interlaced fields to recover the original progressive 24fps cadence, without decimation at this stage
2. **QTGMC Deinterlace:** VapourSynth QTGMC cleans remaining field jitter and combing artifacts on the field-matched output
3. **VDecimate:** Removes duplicate frames re-introduced by QTGMC, returning to clean 24fps progressive
4. **AI Upscale:** Real-ESRGAN with the realesrgan-x4plus-anime model, optimized for drawn/cel content

This pipeline produces significantly cleaner results for animation than standard deinterlacing alone, with reduced field jitter and sharper line art.

---

**Encoding Philosophy**

The goal of this workflow is faithful capture and long-term preservation. Archival masters are recorded losslessly (FFV1/PCM) and retained when storage permits. At present, storage constraints mean that only the viewer/access copy is kept after editing is complete.

Editing is limited to cuts and assembly — no color grading, dropout repair, or image stabilization is applied. VHS artifacts intrinsic to the source (head-switching noise, chroma bleed, line instability, dropouts, analog softness) are left intact rather than corrected.

The viewer copy undergoes additional processing for watchability: deinterlacing via QTGMC, optional AI upscaling (Real-ESRGAN), and light signal conditioning (luma crush, brightness adjustment) before upscaling. These steps improve the viewing experience but are applied only to the access copy — they are not part of the archival record.

This upload represents a **viewer/access copy**. Any limitations in resolution, color fidelity, or stability reflect the characteristics of the original tape and playback hardware.

---

**Source Code**

The scripts used for capture, processing, and encoding are available on GitHub:
https://github.com/RyanEiri/vhsEDIT
