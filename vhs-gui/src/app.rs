use std::path::PathBuf;

use crate::capture::CaptureController;
use crate::config::Config;
use crate::library::{FileKind, Library};
use crate::mpv_view::{MpvView, Source};
use crate::pipeline::PipelineJob;


/// Pair of GPU textures shown side-by-side during an upscale job,
/// annotated with the segment/frame info captured at upload time.
struct UpscalePreviewTextures {
    orig:            egui::TextureHandle,
    upscaled:        egui::TextureHandle,
    /// 1-based index of the segment being processed when this frame was captured.
    segment:         u64,
    total_segments:  u64,
    /// `upscaled_frames` count at the moment of capture.
    frame:           u64,
    /// `segment_frames` (total extracted frames for this segment) at capture time.
    segment_frames:  u64,
}

#[derive(Debug, PartialEq)]
enum CaptureState {
    Idle,
    /// GUI owns V4L2 device for live monitor
    Monitoring,
    /// Waiting for mpv to release the V4L2 fd before spawning ffmpeg
    Releasing,
    /// ffmpeg capture subprocess is running
    Capturing,
}

pub struct App {
    cfg: Config,
    mpv: MpvView,
    library: Library,
    capture: CaptureController,
    state: CaptureState,
    releasing_at: Option<std::time::Instant>,
    /// True once the archival file has been opened in mpv; prevents re-opening on repaints.
    preview_opened: bool,
    /// When the current preview file was last (re)opened; guards against immediate idle false-positive.
    preview_opened_at: Option<std::time::Instant>,
    /// Last non-zero duration seen while previewing the growing archival file.
    capture_preview_duration: f64,
    max_duration: String,
    status: String,
    /// Running Denoise / QTGMC / IVTC job, if any.
    pipeline: Option<PipelineJob>,
    /// Path awaiting delete confirmation; `None` = no pending confirmation.
    confirm_delete: Option<PathBuf>,
    /// Pending rename: `(original_path, edit_buffer)`.
    rename_state: Option<(PathBuf, String)>,
    /// Timestamp of the last upscale preview texture upload.
    /// `None` means we haven't shown one yet (or the job just reset).
    upscale_last_preview_at: Option<std::time::Instant>,
    /// `upscaled_frames` count when we last uploaded preview textures.
    /// Used to detect a directory reset (value drops) between segments.
    upscale_last_preview_frames: u64,
    /// Side-by-side preview textures shown in the central panel while upscaling.
    upscale_preview_textures: Option<UpscalePreviewTextures>,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>) -> anyhow::Result<Self> {
        let cfg = Config::default();
        let mut mpv = MpvView::new(cc)?;
        mpv.wire_repaint(cc.egui_ctx.clone());

        let capture = CaptureController::new(cfg.capture_pgid_file(), cfg.archival_dir());

        let mut library = Library::new();
        library.refresh(&cfg);

        Ok(Self {
            max_duration: cfg.max_capture_duration.clone(),
            capture,
            mpv,
            library,
            state: CaptureState::Idle,
            releasing_at: None,
            preview_opened: false,
            preview_opened_at: None,
            capture_preview_duration: 0.0,
            status: String::new(),
            pipeline: None,
            confirm_delete: None,
            rename_state: None,
            upscale_last_preview_at: None,
            upscale_last_preview_frames: 0,
            upscale_preview_textures: None,
            cfg,
        })
    }

    // -----------------------------------------------------------------------
    // Toolbar
    // -----------------------------------------------------------------------
    fn toolbar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            match self.state {
                CaptureState::Idle => {
                    if ui.button("Monitor").clicked() {
                        let dev = self.cfg.v4l2_device.clone();
                        self.mpv.open(&Source::V4l2(dev));
                        self.state = CaptureState::Monitoring;
                        self.status = "Monitoring live signal".into();
                    }
                    if ui.button("Start Capture").clicked() {
                        self.begin_capture();
                    }
                }
                CaptureState::Monitoring => {
                    ui.label(egui::RichText::new("● MONITOR").color(egui::Color32::GREEN));
                    if ui.button("Start Capture").clicked() {
                        self.begin_capture();
                    }
                    if ui.button("Stop Monitor").clicked() {
                        self.mpv.stop();
                        self.state = CaptureState::Idle;
                        self.status = "Idle".into();
                    }
                }
                CaptureState::Releasing => {
                    ui.label(egui::RichText::new("Releasing device…").italics());
                }
                CaptureState::Capturing => {
                    ui.label(egui::RichText::new("● CAPTURE").color(egui::Color32::RED));
                    let stats = self.capture.stats.lock().unwrap().clone();
                    ui.label(format!(
                        "  {}  frame {}  {}  {}",
                        self.capture.elapsed_str(),
                        stats.frame,
                        stats.time,
                        stats.bitrate
                    ));
                    if ui.button("Stop Capture").clicked() {
                        self.capture.stop();
                        self.preview_opened = false;
                        self.preview_opened_at = None;
                        self.capture_preview_duration = 0.0;
                        self.state = CaptureState::Idle;
                        self.status = "Capture stopped".into();
                        self.library.refresh(&self.cfg);
                    }
                }
            }

            ui.separator();

            if self.state != CaptureState::Capturing {
                if ui.button(if self.mpv.state.paused { "▶" } else { "⏸" }).clicked() {
                    self.mpv.toggle_pause();
                }
            }

            ui.separator();

            ui.label("Cap:");
            ui.add(egui::TextEdit::singleline(&mut self.max_duration).desired_width(70.0));

            ui.separator();
            if ui.button("Refresh").clicked() {
                self.library.refresh(&self.cfg);
            }

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(egui::RichText::new(&self.status).weak().small());
            });
        });
    }

    // -----------------------------------------------------------------------
    // Capture state machine helpers
    // -----------------------------------------------------------------------
    fn begin_capture(&mut self) {
        if self.state == CaptureState::Monitoring {
            self.mpv.stop();
            self.state = CaptureState::Releasing;
            self.releasing_at = Some(std::time::Instant::now());
            self.status = "Releasing device…".into();
        } else {
            self.do_start_capture();
        }
    }

    fn do_start_capture(&mut self) {
        match self.capture.start(&self.cfg.capture_script, &self.max_duration) {
            Ok(()) => {
                self.state = CaptureState::Capturing;
                self.preview_opened = false;
                self.status = "Capturing…".into();
            }
            Err(e) => {
                self.state = CaptureState::Idle;
                self.status = format!("Capture failed to start: {e}");
            }
        }
    }

    // -----------------------------------------------------------------------
    // Pipeline launch helper
    // -----------------------------------------------------------------------

    /// Delete the upscale work directory (`WORK_ROOT/<stem>/`) after a
    /// successful run.  Only removes if the expected output file exists —
    /// a missing output means the job was cancelled/failed mid-concat and
    /// the checkpoints should be kept for resuming.
    ///
    /// Returns a short status string on success or on error, `None` if the
    /// output wasn't found (silent — no message needed, checkpoints kept).
    fn cleanup_upscale_work_dir(
        output_path: &Option<std::path::PathBuf>,
        segments_dir: &Option<std::path::PathBuf>,
    ) -> Option<String> {
        let out = output_path.as_ref()?;
        if !out.exists() {
            return None; // no output — keep checkpoints for resume
        }
        let work_dir = segments_dir.as_ref()?.parent()?;
        match std::fs::remove_dir_all(work_dir) {
            Ok(()) => Some(format!("work dir cleaned up")),
            Err(e) => Some(format!("cleanup failed: {e}")),
        }
    }

    /// Convert an underscore_separated ALLCAPS token to title-case words,
    /// preserving known acronyms (VHS, TV, BBC, DVD, CD) as all-uppercase.
    fn title_words(s: &str) -> String {
        const ACRONYMS: &[&str] = &["VHS", "TV", "BBC", "DVD", "CD", "UK", "US", "USA"];
        s.replace('_', " ")
            .split_whitespace()
            .map(|w| {
                let up = w.to_uppercase();
                if ACRONYMS.contains(&up.as_str()) {
                    up
                } else {
                    let mut chars = w.chars();
                    match chars.next() {
                        None => String::new(),
                        Some(f) => {
                            let head: String = f.to_uppercase().collect();
                            head + &chars.as_str().to_lowercase()
                        }
                    }
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Suggest a human-readable viewer filename for a raw machine-named file.
    ///
    /// `EDIT_MASTER-VHS_TRAILER-THE_GREAT_MOUSE_DETECTIVE_VD.upscale.mkv`
    ///   →  `VHS Trailer — The Great Mouse Detective.mkv`
    ///
    /// Returns the current filename unchanged when the stem doesn't match the
    /// expected `EDIT_MASTER-TYPE-TITLE` pattern, so the user still gets a
    /// pre-filled field they can edit freely.
    fn suggest_viewer_name(path: &std::path::Path) -> String {
        let name = match path.file_name().and_then(|s| s.to_str()) {
            Some(n) => n,
            None => return String::new(),
        };
        // Strip extension layers from right to left.
        let stem = name.strip_suffix(".mkv").unwrap_or(name);
        let stem = stem.strip_suffix(".upscale").unwrap_or(stem);
        let stem = stem.strip_suffix(".viewer").unwrap_or(stem);
        let stem = stem.strip_suffix("_VD").unwrap_or(stem);
        let stem = stem.strip_prefix("EDIT_MASTER-").unwrap_or(stem);

        // Must contain at least one hyphen separating type from title.
        if let Some(dash) = stem.find('-') {
            let type_part  = &stem[..dash];
            let title_part = &stem[dash + 1..];
            // Reject if either part is empty or still contains a known-bad prefix
            if !type_part.is_empty() && !title_part.is_empty() {
                return format!(
                    "{} \u{2014} {}.mkv",   // em dash U+2014
                    Self::title_words(type_part),
                    Self::title_words(title_part),
                );
            }
        }
        // Fallback: return the original filename for free-form editing.
        name.to_owned()
    }

    fn launch_pipeline(
        &mut self,
        label: String,
        script: std::path::PathBuf,
        input: std::path::PathBuf,
        envs: &[(&str, &str)],
        extra_args: &[&str],
    ) {
        let log_dir = self.cfg.log_dir();
        match PipelineJob::start(label, &script, &input, envs, extra_args, &log_dir) {
            Ok(job) => {
                self.status = format!("Started: {}", job.label);
                self.pipeline = Some(job);
            }
            Err(e) => self.status = format!("Failed to start job: {e}"),
        }
    }

    // -----------------------------------------------------------------------
    // File action panel (shown for any selected library entry)
    // -----------------------------------------------------------------------

    /// Compute the output path for an upscale job.
    /// Strips a trailing `.viewer` component from the stem so viewer files don't
    /// accumulate double suffixes, then places the result in `captures/viewer/`.
    fn upscale_output(&self, input: &std::path::Path) -> std::path::PathBuf {
        let stem = input
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("out");
        let clean = stem.strip_suffix(".viewer").unwrap_or(stem);
        self.cfg.viewer_dir().join(format!("{clean}.upscale.mkv"))
    }

    /// Returns the `segments/` directory inside the upscale work dir for the given input.
    /// Matches the script's `WORK_ROOT/<BASE_STEM>/segments/` path.
    fn upscale_segments_dir(&self, input: &std::path::Path) -> std::path::PathBuf {
        let stem = input.file_stem().and_then(|s| s.to_str()).unwrap_or("out");
        self.cfg.upscale_work_root().join(stem).join("segments")
    }

    /// Like `launch_pipeline()` but chains `with_upscale_tracking()` so the job
    /// shows dual progress bars (segment + total).
    ///
    /// Always sets `BATCH_SIZE=2` — the ROCm x4plus models OOM at the driver
    /// default of 8 on 16 GB VRAM (deep intermediate activations at 720×480 4×).
    fn launch_upscale(
        &mut self,
        label: String,
        script: std::path::PathBuf,
        input: std::path::PathBuf,
        envs: &[(&str, &str)],
        extra_args: &[&str],
    ) {
        let log_dir = self.cfg.log_dir();
        let seg_dir = self.upscale_segments_dir(&input);
        // extra_args[0] is the output path passed as $2 to the script.
        let out_path = extra_args.first()
            .map(|s| std::path::PathBuf::from(s));
        // Extend caller's envs with the ROCm batch-size cap.
        let mut full_envs: Vec<(&str, &str)> = envs.to_vec();
        full_envs.push(("BATCH_SIZE", "2"));
        match PipelineJob::start(label, &script, &input, &full_envs, extra_args, &log_dir) {
            Ok(job) => {
                let job = job.with_upscale_tracking(
                    seg_dir,
                    out_path.unwrap_or_default(),
                );
                self.status = format!("Started: {}", job.label);
                self.upscale_last_preview_at = None;
                self.upscale_last_preview_frames = 0;
                self.upscale_preview_textures = None;
                self.pipeline = Some(job);
            }
            Err(e) => self.status = format!("Failed to start job: {e}"),
        }
    }

    /// Buttons shown depend on where the file sits in the pipeline:
    ///
    /// * Archival      → [Denoise] [Denoise+QTGMC] [🗑 Delete]
    /// * Stabilized    → [QTGMC] [IVTC] [🗑 Delete]
    /// * EditMaster    → [VDecimate] [Viewer Encode] [🗑 Delete]
    /// * EditMasterVD  → [Viewer Encode] [Upscale Film] [Upscale Film B&W] [Upscale Anime] [🗑 Delete]
    /// * Viewer        → [Upscale] [Upscale B&W] [Upscale Anime] [🗑 Delete]
    fn file_actions_panel(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let entry = match self.library.selected_entry() {
            Some(e) => e.clone(),
            None => return,
        };

        ui.separator();
        ui.label(egui::RichText::new(&entry.name).small().weak());

        let busy = self.pipeline.is_some()
            || self.confirm_delete.is_some()
            || self.rename_state.is_some();

        // --- Action buttons (vary by pipeline stage) ---
        ui.add_enabled_ui(!busy, |ui| {
            ui.horizontal_wrapped(|ui| {
                match entry.kind {
                    FileKind::Archival => {
                        if ui.button("Denoise").clicked() {
                            self.launch_pipeline(
                                format!("Denoise {}", entry.name),
                                self.cfg.denoise_script(),
                                entry.path.clone(),
                                &[],
                                &[],
                            );
                        }
                        if ui.button("Denoise+QTGMC").clicked() {
                            self.launch_pipeline(
                                format!("Denoise+QTGMC {}", entry.name),
                                self.cfg.process_script(),
                                entry.path.clone(),
                                &[("NO_LAUNCH", "1")],
                                &[],
                            );
                        }
                    }
                    FileKind::Stabilized => {
                        if ui.button("QTGMC").clicked() {
                            self.launch_pipeline(
                                format!("QTGMC {}", entry.name),
                                self.cfg.qtgmc_only_script(),
                                entry.path.clone(),
                                &[],
                                &[],
                            );
                        }
                        if ui.button("IVTC").clicked() {
                            self.launch_pipeline(
                                format!("IVTC {}", entry.name),
                                self.cfg.ivtc_script(),
                                entry.path.clone(),
                                &[],
                                &[],
                            );
                        }
                    }
                    FileKind::EditMaster => {
                        if ui.button("VDecimate").clicked() {
                            self.launch_pipeline(
                                format!("VDecimate {}", entry.name),
                                self.cfg.vdecimate_script(),
                                entry.path.clone(),
                                &[],
                                &[],
                            );
                        }
                        if ui.button("Viewer Encode").clicked() {
                            self.launch_pipeline(
                                format!("Viewer Encode {}", entry.name),
                                self.cfg.viewer_encode_script(),
                                entry.path.clone(),
                                &[],
                                &[],
                            );
                        }
                    }
                    FileKind::EditMasterVD => {
                        if ui.button("Viewer Encode").clicked() {
                            self.launch_pipeline(
                                format!("Viewer Encode {}", entry.name),
                                self.cfg.viewer_encode_script(),
                                entry.path.clone(),
                                &[],
                                &[],
                            );
                        }
                        if ui.button("Upscale Film").clicked() {
                            let out = self.upscale_output(&entry.path);
                            let out_str = out.to_string_lossy().into_owned();
                            self.launch_upscale(
                                format!("Upscale Film {}", entry.name),
                                self.cfg.upscale_script(),
                                entry.path.clone(),
                                &[("UPSCALE_BACKEND", "rocm")],
                                &[&out_str],
                            );
                        }
                        if ui.button("Upscale Film B&W").clicked() {
                            let out = self.upscale_output(&entry.path);
                            let out_str = out.to_string_lossy().into_owned();
                            self.launch_upscale(
                                format!("Upscale Film B&W {}", entry.name),
                                self.cfg.upscale_bw_script(),
                                entry.path.clone(),
                                &[("UPSCALE_BACKEND", "rocm")],
                                &[&out_str],
                            );
                        }
                        if ui.button("Upscale Anime").clicked() {
                            let out = self.upscale_output(&entry.path);
                            let out_str = out.to_string_lossy().into_owned();
                            self.launch_upscale(
                                format!("Upscale Anime {}", entry.name),
                                self.cfg.upscale_anime_script(),
                                entry.path.clone(),
                                &[("UPSCALE_BACKEND", "rocm")],
                                &[&out_str],
                            );
                        }
                    }
                    FileKind::Viewer => {
                        if ui.button("Upscale").clicked() {
                            let out = self.upscale_output(&entry.path);
                            let out_str = out.to_string_lossy().into_owned();
                            self.launch_upscale(
                                format!("Upscale {}", entry.name),
                                self.cfg.upscale_script(),
                                entry.path.clone(),
                                &[("UPSCALE_BACKEND", "rocm")],
                                &[&out_str],
                            );
                        }
                        if ui.button("Upscale B&W").clicked() {
                            let out = self.upscale_output(&entry.path);
                            let out_str = out.to_string_lossy().into_owned();
                            self.launch_upscale(
                                format!("Upscale B&W {}", entry.name),
                                self.cfg.upscale_bw_script(),
                                entry.path.clone(),
                                &[("UPSCALE_BACKEND", "rocm")],
                                &[&out_str],
                            );
                        }
                        if ui.button("Upscale Anime").clicked() {
                            let out = self.upscale_output(&entry.path);
                            let out_str = out.to_string_lossy().into_owned();
                            self.launch_upscale(
                                format!("Upscale Anime {}", entry.name),
                                self.cfg.upscale_anime_script(),
                                entry.path.clone(),
                                &[("UPSCALE_BACKEND", "rocm")],
                                &[&out_str],
                            );
                        }
                    }
                }

                if matches!(entry.kind, FileKind::Viewer) {
                    if ui.button("Rename…").clicked() {
                        let suggestion = Self::suggest_viewer_name(&entry.path);
                        self.rename_state = Some((entry.path.clone(), suggestion));
                    }
                }
                if ui.button("🗑 Delete").clicked() {
                    self.confirm_delete = Some(entry.path.clone());
                }
            });
        });

        // --- Delete confirmation ---
        if let Some(ref path) = self.confirm_delete.clone() {
            if path == &entry.path {
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new("Move to Trash?").color(egui::Color32::RED));
                    if ui.button("✓ Yes").clicked() {
                        if let Err(e) = trash::delete(path) {
                            self.status = format!("Trash failed: {e}");
                        } else {
                            self.status = format!("Trashed {}", entry.name);
                        }
                        self.confirm_delete = None;
                        self.library.refresh(&self.cfg);
                    }
                    if ui.button("✗ No").clicked() {
                        self.confirm_delete = None;
                    }
                });
            }
        }

        // --- Rename UI ---
        // Collect click results while holding the borrow on rename_state,
        // then apply the mutation after releasing it.
        let rename_action: Option<Result<String, ()>> =
            if let Some((ref orig, ref mut edit)) = self.rename_state {
                if orig == &entry.path {
                    ui.separator();
                    ui.label(egui::RichText::new("Rename to:").small().weak());
                    ui.add(
                        egui::TextEdit::singleline(edit)
                            .desired_width(f32::INFINITY)
                            .hint_text("filename.mkv"),
                    );
                    let mut action = None;
                    ui.horizontal(|ui| {
                        if ui.button("✓ OK").clicked() {
                            action = Some(Ok(edit.clone()));
                        }
                        if ui.button("✗ Cancel").clicked() {
                            action = Some(Err(()));
                        }
                    });
                    action
                } else {
                    None
                }
            } else {
                None
            };

        match rename_action {
            Some(Ok(new_name)) => {
                self.rename_state = None;
                let new_name = new_name.trim().to_owned();
                if !new_name.is_empty() {
                    let new_name = if new_name.ends_with(".mkv") {
                        new_name
                    } else {
                        format!("{new_name}.mkv")
                    };
                    let new_path = entry.path
                        .parent()
                        .unwrap_or_else(|| std::path::Path::new("."))
                        .join(&new_name);
                    if new_path.exists() {
                        self.status = format!("Rename failed: {new_name} already exists");
                    } else {
                        match std::fs::rename(&entry.path, &new_path) {
                            Ok(()) => {
                                self.status = format!("Renamed to {new_name}");
                                self.library.refresh(&self.cfg);
                            }
                            Err(e) => self.status = format!("Rename failed: {e}"),
                        }
                    }
                }
            }
            Some(Err(())) => {
                self.rename_state = None;
            }
            None => {}
        }

        // --- Running job progress ---
        // Collect button click results in one immutable-borrow pass, then apply
        // any mutations that need &mut job in a second pass.
        let (do_toggle_pause, do_stop_after_seg, do_cancel) = if let Some(ref job) = self.pipeline {
            ui.separator();
            ui.label(
                egui::RichText::new(format!("● {}", job.label))
                    .color(egui::Color32::from_rgb(80, 200, 80))
                    .small(),
            );

            // Pulse helper — sine-wave fill used when deterministic value is unavailable.
            let pulse = {
                let t = ctx.input(|i| i.time);
                ((t * 0.4).sin() * 0.5 + 0.5) as f32
            };

            if job.is_upscale {
                // ── Total bar ──────────────────────────────────────────────
                let total_fill = job.total_progress().unwrap_or(0.0);
                ui.label(egui::RichText::new(
                    format!("Total  {}/{} segments", job.completed_segments, job.total_segments)
                ).small());
                ui.add(egui::ProgressBar::new(total_fill).animate(false));

                // ── Segment bar ────────────────────────────────────────────
                let seg_fill = job.segment_progress().unwrap_or(pulse);
                ui.label(egui::RichText::new("Segment").small());
                ui.add(egui::ProgressBar::new(seg_fill).animate(true));
            } else {
                // Single time-based bar for all non-upscale jobs.
                let fill = job.progress().unwrap_or(pulse);
                ui.add(egui::ProgressBar::new(fill).animate(true));
            }

            // Frame counter + elapsed
            let frame_txt = if job.is_upscale {
                format!("frame {} / {}  {}", job.upscaled_frames, job.segment_frames, job.elapsed_str())
            } else if job.total_frames > 0 {
                format!("frame {} / {}  {}", job.current_frame, job.total_frames, job.elapsed_str())
            } else {
                format!("frame {}  {}", job.current_frame, job.elapsed_str())
            };
            ui.label(egui::RichText::new(frame_txt).small());

            // Buttons row
            let mut toggle_pause = false;
            let mut stop_after   = false;
            let mut cancel       = false;
            ui.horizontal(|ui| {
                if job.is_upscale {
                    let pause_label = if job.paused { "Resume" } else { "Pause" };
                    if ui.button(pause_label).clicked() { toggle_pause = true; }

                    if job.stopping_after_segment() {
                        ui.label(egui::RichText::new("Stopping…").weak().small());
                    } else if ui.button("Stop after Segment").clicked() {
                        stop_after = true;
                    }
                }
                if ui.button("Cancel").clicked() { cancel = true; }
            });

            // Keep repainting while a job is running.
            ctx.request_repaint_after(std::time::Duration::from_secs(1));

            (toggle_pause, stop_after, cancel)
        } else {
            (false, false, false)
        };

        // Apply mutations (require &mut job, can't overlap the read borrow above).
        if do_toggle_pause {
            if let Some(ref mut job) = self.pipeline { job.toggle_pause(); }
        }
        if do_stop_after_seg {
            if let Some(ref mut job) = self.pipeline { job.request_stop_after_segment(); }
        }
        if do_cancel {
            if let Some(ref job) = self.pipeline { job.cancel(); }
        }
    }
} // impl App

impl eframe::App for App {
    fn ui(&mut self, _ui: &mut egui::Ui, _frame: &mut eframe::Frame) {}

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        // 1. Render mpv frame into off-screen FBO (must be before any UI draw calls)
        if let Some(gl) = frame.gl() {
            self.mpv.render_frame(gl);
        }

        // 2. Poll capture subprocess and pipeline jobs; handle state transitions
        self.capture.poll();

        // Poll any running pipeline job; refresh library when it finishes.
        if let Some(ref mut job) = self.pipeline {
            job.poll();

            // Upscale frame preview: time-based (every ~4 s) side-by-side texture pair.
            if job.is_upscale && !job.done {
                const PREVIEW_INTERVAL: std::time::Duration =
                    std::time::Duration::from_secs(4);

                // If frames_up/ was cleared for a new segment (count drops), reset so
                // we show a preview as soon as the first frames of the next segment arrive.
                if job.upscaled_frames < self.upscale_last_preview_frames {
                    self.upscale_last_preview_at = None;
                    self.upscale_last_preview_frames = 0;
                }

                let due = self.upscale_last_preview_at
                    .map(|t| t.elapsed() >= PREVIEW_INTERVAL)
                    .unwrap_or(true); // never shown yet → show immediately

                if due && job.upscaled_frames > 0 {
                    let up_dir = job.frames_up_dir.as_deref();
                    let fr_dir = job.frames_dir.as_deref();
                    if let (Some(up_d), Some(fr_d)) = (up_dir, fr_dir) {
                        if let Some(up_path) = latest_jpg_in_dir(up_d) {
                            if let Some(fname) = up_path.file_name() {
                                let orig_path = fr_d.join(fname);
                                if let (Some(orig_img), Some(up_img)) = (
                                    load_jpeg_as_egui_image(&orig_path),
                                    load_jpeg_as_egui_image(&up_path),
                                ) {
                                    // Snapshot the segment/frame info at upload time.
                                    let seg         = job.completed_segments + 1;
                                    let total_segs  = job.total_segments;
                                    let frame       = job.upscaled_frames;
                                    let seg_frames  = job.segment_frames;

                                    match self.upscale_preview_textures {
                                        Some(ref mut t) => {
                                            t.orig.set(orig_img, egui::TextureOptions::LINEAR);
                                            t.upscaled.set(up_img, egui::TextureOptions::LINEAR);
                                            t.segment        = seg;
                                            t.total_segments = total_segs;
                                            t.frame          = frame;
                                            t.segment_frames = seg_frames;
                                        }
                                        None => {
                                            self.upscale_preview_textures =
                                                Some(UpscalePreviewTextures {
                                                    orig: ctx.load_texture(
                                                        "upscale_orig",
                                                        orig_img,
                                                        egui::TextureOptions::LINEAR,
                                                    ),
                                                    upscaled: ctx.load_texture(
                                                        "upscale_up",
                                                        up_img,
                                                        egui::TextureOptions::LINEAR,
                                                    ),
                                                    segment:        seg,
                                                    total_segments: total_segs,
                                                    frame,
                                                    segment_frames: seg_frames,
                                                });
                                        }
                                    }
                                    self.upscale_last_preview_at = Some(std::time::Instant::now());
                                    self.upscale_last_preview_frames = job.upscaled_frames;
                                }
                            }
                        }
                    }
                }

                // Drive the update loop even when mpv is idle (no render callbacks firing).
                ctx.request_repaint_after(std::time::Duration::from_secs(1));
            }

            if job.done {
                let finish_status = if job.is_upscale {
                    Self::cleanup_upscale_work_dir(&job.output_path, &job.segments_dir)
                        .map(|msg| format!("{} finished — {msg}", job.label))
                        .unwrap_or_else(|| format!("{} finished", job.label))
                } else {
                    format!("{} finished", job.label)
                };
                self.status = finish_status;
                self.upscale_last_preview_at = None;
                self.upscale_last_preview_frames = 0;
                self.upscale_preview_textures = None;
                self.pipeline = None;
                self.library.refresh(&self.cfg);
            }
        }

        // Releasing → Capturing once mpv is idle or 1 s timeout
        if self.state == CaptureState::Releasing {
            let timed_out = self.releasing_at
                .map(|t| t.elapsed() > std::time::Duration::from_millis(1000))
                .unwrap_or(true);
            if self.mpv.state.idle || timed_out {
                self.releasing_at = None;
                self.do_start_capture();
            } else {
                ctx.request_repaint();
            }
        }

        // While capturing: open archival file as soon as it appears; re-seek to live on EOF
        if self.state == CaptureState::Capturing {
            ctx.request_repaint_after(std::time::Duration::from_secs(1));

            // Track duration while mpv is playing so we know where to seek on EOF
            if self.mpv.state.duration > 0.0 {
                self.capture_preview_duration = self.mpv.state.duration;
            }

            // Open the file the moment it exists
            if !self.preview_opened {
                if let Some(path) = self.capture.output_path.clone() {
                    self.mpv.open(&Source::File(path));
                    self.preview_opened = true;
                    self.preview_opened_at = Some(std::time::Instant::now());
                    self.status = "Capturing… (previewing)".into();
                }
            }

            // When mpv hits EOF on the growing file, jump to near the live position.
            // Guard with a 2 s grace period so we don't react to the idle state
            // that exists briefly while mpv is first loading the file.
            if self.preview_opened && self.mpv.state.idle && self.capture.is_running() {
                let settled = self.preview_opened_at
                    .map(|t| t.elapsed() > std::time::Duration::from_secs(2))
                    .unwrap_or(false);
                if settled {
                    if let Some(path) = self.capture.output_path.clone() {
                        let seek_to = (self.capture_preview_duration - 2.0).max(0.0);
                        self.mpv.open_at(&Source::File(path), seek_to);
                        self.preview_opened_at = Some(std::time::Instant::now());
                    }
                }
            }

            if !self.capture.is_running() {
                self.preview_opened = false;
                self.preview_opened_at = None;
                self.capture_preview_duration = 0.0;
                self.state = CaptureState::Idle;
                self.status = "Capture ended".into();
                self.library.refresh(&self.cfg);
            }
        }

        // 3. Build UI
        egui::TopBottomPanel::top("toolbar").show(ctx, |ui| {
            self.toolbar(ui);
        });

        egui::SidePanel::left("library")
            .resizable(true)
            .default_width(220.0)
            .show(ctx, |ui| {
                ui.heading("Library");
                if let Some(entry) = self.library.show(ui) {
                    self.status = format!("Opening: {}", entry.name);
                    self.mpv.open(&Source::File(entry.path));
                }
                // Show pipeline actions for any selected file.
                if self.library.selected_entry().is_some() {
                    self.file_actions_panel(ui, ctx);
                }
            });

        egui::CentralPanel::default().show(ctx, |ui| {
            let upscaling = self.pipeline.as_ref().map(|j| j.is_upscale).unwrap_or(false);
            if upscaling {
                // Side-by-side: original frame on left, Real-ESRGAN upscaled on right.
                if let Some(ref textures) = self.upscale_preview_textures {
                    let available = ui.available_size();
                    let label_h = 18.0;
                    let gap = 6.0;
                    let panel_w = (available.x - gap) / 2.0;
                    let panel_h = (panel_w * 3.0 / 4.0).min(available.y - label_h - 4.0);

                    // "Seg 2 / 5  ·  Frame 245 / 900"
                    let seg_label = format!(
                        "Seg {} / {}  ·  Frame {} / {}",
                        textures.segment,
                        textures.total_segments,
                        textures.frame,
                        textures.segment_frames,
                    );

                    ui.horizontal(|ui| {
                        ui.vertical(|ui| {
                            ui.horizontal(|ui| {
                                ui.label(
                                    egui::RichText::new("Original  720×480")
                                        .small()
                                        .weak(),
                                );
                                ui.with_layout(
                                    egui::Layout::right_to_left(egui::Align::Center),
                                    |ui| {
                                        ui.label(
                                            egui::RichText::new(&seg_label).small().weak(),
                                        );
                                    },
                                );
                            });
                            let (rect, _) = ui.allocate_exact_size(
                                egui::vec2(panel_w, panel_h),
                                egui::Sense::hover(),
                            );
                            let uv = egui::Rect::from_min_max(
                                egui::pos2(0.0, 0.0),
                                egui::pos2(1.0, 1.0),
                            );
                            ui.painter().image(
                                textures.orig.id(),
                                rect,
                                uv,
                                egui::Color32::WHITE,
                            );
                        });
                        ui.add_space(gap);
                        ui.vertical(|ui| {
                            ui.label(
                                egui::RichText::new("Upscaled  4×").small().weak(),
                            );
                            let (rect, _) = ui.allocate_exact_size(
                                egui::vec2(panel_w, panel_h),
                                egui::Sense::hover(),
                            );
                            let uv = egui::Rect::from_min_max(
                                egui::pos2(0.0, 0.0),
                                egui::pos2(1.0, 1.0),
                            );
                            ui.painter().image(
                                textures.upscaled.id(),
                                rect,
                                uv,
                                egui::Color32::WHITE,
                            );
                        });
                    });
                } else {
                    // Job just started, no frames yet.
                    ui.centered_and_justified(|ui| {
                        ui.label(
                            egui::RichText::new(
                                "Upscaling…\nPreview frames will appear shortly",
                            )
                            .weak(),
                        );
                    });
                }
            } else {
                self.mpv.show(ui);
                if self.mpv.state.duration > 0.0 {
                    let pos = format_time(self.mpv.state.time_pos);
                    let dur = format_time(self.mpv.state.duration);
                    ui.label(format!("{pos} / {dur}"));
                } else if self.mpv.state.idle {
                    ui.centered_and_justified(|ui| {
                        ui.label(
                            egui::RichText::new(
                                "No media\nSelect a file from the library or start monitoring",
                            )
                            .weak(),
                        );
                    });
                }
            }
        });
    }
}

/// Decode a JPEG file into an `egui::ColorImage` suitable for texture upload.
/// Returns `None` on any I/O or decode error (e.g. partially-written file).
fn load_jpeg_as_egui_image(path: &std::path::Path) -> Option<egui::ColorImage> {
    let img = image::open(path).ok()?.into_rgba8();
    let (w, h) = img.dimensions();
    Some(egui::ColorImage::from_rgba_unmultiplied(
        [w as usize, h as usize],
        img.as_raw(),
    ))
}

/// Returns the path of the lexicographically last `.jpg` file in `dir`.
/// Used to find the most recently written Real-ESRGAN output frame for preview.
fn latest_jpg_in_dir(dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("jpg"))
        .collect();
    entries.sort_by_key(|e| e.file_name());
    entries.last().map(|e| e.path())
}

fn format_time(secs: f64) -> String {
    let s = secs as u64;
    let h = s / 3600;
    let m = (s % 3600) / 60;
    let sc = s % 60;
    if h > 0 {
        format!("{h}:{m:02}:{sc:02}")
    } else {
        format!("{m}:{sc:02}")
    }
}
