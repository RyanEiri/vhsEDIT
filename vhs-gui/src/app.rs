use crate::config::Config;
use crate::mpv_view::MpvView;
use crate::panels::monitor::{CaptureState, MonitorPanel};
use crate::panels::upscale::UpscalePanel;
use crate::panels::ViewMode;

pub struct App {
    cfg:       Config,
    mpv:       MpvView,
    monitor:   MonitorPanel,
    upscale:   UpscalePanel,
    view_mode: ViewMode,
    status:    String,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>) -> anyhow::Result<Self> {
        let cfg = Config::default();
        let mut mpv = MpvView::new(cc)?;
        mpv.wire_repaint(cc.egui_ctx.clone());

        let monitor = MonitorPanel::new(&cfg);
        let upscale = UpscalePanel::new(&cfg);

        Ok(Self {
            monitor,
            upscale,
            mpv,
            view_mode: ViewMode::Monitor,
            status: String::new(),
            cfg,
        })
    }

    fn toolbar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let needs_refresh = self.monitor.toolbar_section(
                ui,
                &mut self.mpv,
                &self.cfg,
                &mut self.status,
            );
            if needs_refresh {
                self.upscale.refresh_library(&self.cfg);
            }

            ui.separator();

            if self.monitor.state != CaptureState::Capturing {
                if ui.button(if self.mpv.state.paused { "▶" } else { "⏸" }).clicked() {
                    self.mpv.toggle_pause();
                }
            }

            ui.separator();

            ui.label("Cap:");
            ui.add(
                egui::TextEdit::singleline(&mut self.monitor.max_duration)
                    .desired_width(70.0),
            );

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(egui::RichText::new(&self.status).weak().small());
            });
        });
    }

    fn show_rail(&mut self, ctx: &egui::Context) {
        egui::SidePanel::left("rail")
            .exact_width(44.0)
            .resizable(false)
            .show(ctx, |ui| {
                ui.add_space(6.0);
                ui.vertical_centered(|ui| {
                    let mon_sel =
                        egui::SelectableLabel::new(self.view_mode == ViewMode::Monitor, "⏺");
                    if ui.add(mon_sel).on_hover_text("Monitor").clicked() {
                        self.view_mode = ViewMode::Monitor;
                    }
                    ui.add_space(4.0);
                    let up_sel =
                        egui::SelectableLabel::new(self.view_mode == ViewMode::Upscale, "⬆");
                    if ui.add(up_sel).on_hover_text("Upscale").clicked() {
                        self.view_mode = ViewMode::Upscale;
                    }

                    // Input-settings toggle — only in Monitor view.
                    if self.view_mode == ViewMode::Monitor {
                        ui.add_space(8.0);
                        ui.separator();
                        ui.add_space(4.0);
                        let settings_sel = egui::SelectableLabel::new(
                            self.monitor.input_panel_open,
                            "⚙",
                        );
                        if ui.add(settings_sel).on_hover_text("Input Settings").clicked() {
                            self.monitor.input_panel_open = !self.monitor.input_panel_open;
                        }
                    }
                });
            });
    }
}

impl eframe::App for App {
    fn ui(&mut self, _ui: &mut egui::Ui, _frame: &mut eframe::Frame) {}

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        // 1. Render mpv frame into off-screen FBO (must precede any UI draw calls).
        if let Some(gl) = frame.gl() {
            self.mpv.render_frame(gl);
        }

        // 2. Poll capture state machine.
        if self.monitor.poll(ctx, &mut self.mpv, &self.cfg, &mut self.status) {
            self.upscale.refresh_library(&self.cfg);
        }

        // 3. Poll upscale/pipeline job (keeps running even when Monitor view is active).
        self.upscale.poll(ctx, &self.cfg, &mut self.status);

        // 4. Build UI.
        egui::TopBottomPanel::top("toolbar").show(ctx, |ui| {
            self.toolbar(ui);
        });

        // Icon-only left rail: Monitor (⏺) | Upscale (⬆).
        self.show_rail(ctx);

        // Monitor view: collapsible Input settings panel (V4L2 hardware controls).
        if self.view_mode == ViewMode::Monitor && self.monitor.input_panel_open {
            egui::SidePanel::left("input")
                .resizable(true)
                .default_width(220.0)
                .show(ctx, |ui| {
                    self.monitor.show_input_panel(ui);
                });
        }

        // Upscale view: file library sidebar.
        if self.view_mode == ViewMode::Upscale {
            egui::SidePanel::left("library")
                .resizable(true)
                .default_width(220.0)
                .show(ctx, |ui| {
                    ui.horizontal(|ui| {
                        ui.heading("Library");
                        if ui.small_button("⟳").on_hover_text("Refresh").clicked() {
                            self.upscale.refresh_library(&self.cfg);
                        }
                    });
                    egui::ScrollArea::vertical()
                        .stick_to_bottom(true)
                        .show(ui, |ui| {
                            self.upscale.show_sidebar(
                                ui, ctx, &mut self.mpv, &self.cfg, &mut self.status,
                            );
                        });
                });
        }

        // Central panel: upscale preview when a job is active, otherwise mpv.
        egui::CentralPanel::default().show(ctx, |ui| {
            if self.upscale.is_upscaling() {
                self.upscale.show_central(ui);
            } else {
                let cap_osd = if self.monitor.state == CaptureState::Capturing {
                    Some(self.monitor.capture.elapsed_str())
                } else {
                    None
                };
                self.mpv.show(ui, cap_osd.as_deref());
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
