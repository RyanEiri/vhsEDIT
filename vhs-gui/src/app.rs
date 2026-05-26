use crate::capture::CaptureController;
use crate::config::Config;
use crate::library::Library;
use crate::mpv_view::{MpvView, Source};

const PREVIEW_DELAY_SECS: u64 = 10;

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
    /// Set when the output file is discovered; preview opens after PREVIEW_DELAY_SECS.
    /// Stays Some after opening so the countdown doesn't re-arm on the next repaint.
    preview_at: Option<std::time::Instant>,
    /// True once the archival file has been opened in mpv; prevents re-arming preview_at.
    preview_opened: bool,
    max_duration: String,
    status: String,
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
            preview_at: None,
            preview_opened: false,
            status: String::new(),
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
                        self.mpv.stop();
                        self.preview_at = None;
                        self.preview_opened = false;
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
                self.preview_at = None;
                self.preview_opened = false;
                self.status = format!("Capturing… (preview in {PREVIEW_DELAY_SECS}s)");
            }
            Err(e) => {
                self.state = CaptureState::Idle;
                self.status = format!("Capture failed to start: {e}");
            }
        }
    }
}

impl eframe::App for App {
    fn ui(&mut self, _ui: &mut egui::Ui, _frame: &mut eframe::Frame) {}

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        // 1. Render mpv frame into off-screen FBO (must be before any UI draw calls)
        if let Some(gl) = frame.gl() {
            self.mpv.render_frame(gl);
        }

        // 2. Poll capture subprocess and handle state transitions
        self.capture.poll();

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

        // While capturing: open the archival file for preview once it appears + delay elapsed
        if self.state == CaptureState::Capturing {
            ctx.request_repaint_after(std::time::Duration::from_secs(1));

            // Arm the countdown once the output file exists and we haven't opened it yet.
            if self.preview_at.is_none() && !self.preview_opened {
                if self.capture.output_path.is_some() {
                    self.preview_at = Some(std::time::Instant::now());
                }
            }

            if let Some(t) = self.preview_at {
                let elapsed = t.elapsed().as_secs();
                if elapsed < PREVIEW_DELAY_SECS {
                    let remaining = PREVIEW_DELAY_SECS - elapsed;
                    self.status = format!("Capturing… (preview in {remaining}s)");
                } else if !self.preview_opened {
                    if let Some(path) = self.capture.output_path.clone() {
                        self.mpv.open(&Source::File(path));
                        self.preview_opened = true; // don't re-open on subsequent repaints
                        self.status = "Capturing… (previewing archival file)".into();
                    }
                }
            }

            // If capture exited unexpectedly
            if !self.capture.is_running() {
                self.state = CaptureState::Idle;
                self.preview_at = None;
                self.preview_opened = false;
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
            });

        egui::CentralPanel::default().show(ctx, |ui| {
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
        });
    }
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
