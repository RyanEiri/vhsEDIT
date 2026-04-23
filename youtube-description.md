**Technical note:** Viewer/access encode (640×480, 4:3 square pixel, progressive) from analog VHS. SD Rec.601 color, H.264/AAC, edited in Kdenlive and encoded with FFmpeg on Linux.

Captured from VHS using a Sony SLV-N500 VCR and a MacroSilicon MS210x USB capture device via direct composite.

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

Direct composite from VCR to USB capture device.

---

**AI Upscale (when applicable)**

• **Model:** Real-ESRGAN (realesrgan-x4plus) via realesrgan-ncnn-vulkan  
• **GPU:** AMD RX 7800 XT (Vulkan)  
• **Process:** 4× internal upscale → downscale to 2× final (1280×960 from 720×480)  
• **Output resolution:** 1280×960, 4:3 (DAR-correct)  
• **Pre-processing:** Light denoise (hqdn3d) and luma crush before upscaling. Default: small crush (threshold 16); medium/heavy presets for noisier sources.  
• **Output encoding:** H.264 (libx264), CRF 21  
• **Animation variant:** Uses the realesrgan-x4plus-anime model for drawn/cel content  

---

**Animation Pipeline (when applicable)**

Animated content goes through a dedicated processing chain before upscaling:

1. **IVTC:** VapourSynth vivtc VFM recovers original progressive 24fps cadence from telecined 30fps
2. **QTGMC:** Cleans remaining field jitter and combing on the field-matched output
3. **VDecimate:** Removes QTGMC-reintroduced duplicates, returning to clean 24fps
4. **AI Upscale:** Real-ESRGAN with realesrgan-x4plus-anime model

---

**Encoding Philosophy**

Archival masters are recorded losslessly (FFV1/PCM) and retained when storage permits. Editing is limited to cuts and assembly — no color grading, dropout repair, or image stabilization. VHS artifacts are left intact.

The viewer copy undergoes QTGMC deinterlacing, optional AI upscaling, and light signal conditioning (luma crush, brightness adjustment). These steps are applied to the access copy only.

This upload represents a **viewer/access copy**. Any limitations reflect the original tape and playback hardware.

---

**Source Code**

The scripts used for capture, processing, and encoding are available on GitHub:
https://github.com/RyanEiri/vhsEDIT
