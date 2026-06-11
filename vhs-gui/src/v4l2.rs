use std::collections::BTreeMap;
use std::time::{Duration, Instant};

pub struct V4l2Control {
    pub name:    &'static str,
    pub label:   &'static str,
    pub min:     i32,
    pub max:     i32,
    pub default: i32,
    pub value:   i32,
    dirty_since: Option<Instant>,
}

pub struct V4l2Controls {
    device:     String,
    pub ctrls:  Vec<V4l2Control>,
}

// (name, label, min, max, default) — ranges confirmed against the MS210x card.
static DEFAULTS: &[(&str, &str, i32, i32, i32)] = &[
    ("brightness", "Brightness", 0, 255, 25),
    ("contrast",   "Contrast",   0, 255, 127),
    ("saturation", "Saturation", 0, 255, 127),
    ("hue",        "Hue",        0, 127, 0),
    ("gamma",      "Gamma",      0, 50,  0),
];

impl V4l2Controls {
    pub fn new(device: &str) -> Self {
        let mut ctrls: Vec<V4l2Control> = DEFAULTS
            .iter()
            .map(|(name, label, min, max, default)| V4l2Control {
                name,
                label,
                min:     *min,
                max:     *max,
                default: *default,
                value:   *default,
                dirty_since: None,
            })
            .collect();

        // Try to read actual current values from the driver; fall back to defaults.
        if let Some(values) = query_values(device) {
            for ctrl in &mut ctrls {
                if let Some(&v) = values.get(ctrl.name) {
                    ctrl.value = v;
                }
            }
        }

        Self { device: device.to_owned(), ctrls }
    }

    /// Flush any control that has been dirty for > 120 ms.
    /// Call every frame from MonitorPanel::poll — at most ~8 v4l2-ctl spawns/sec.
    pub fn flush_debounced(&mut self) {
        // Capture device as a local &str to allow disjoint field borrows inside the loop.
        let device = self.device.as_str();
        for ctrl in &mut self.ctrls {
            if let Some(t) = ctrl.dirty_since {
                if t.elapsed() > Duration::from_millis(120) {
                    fire_set_ctrl(device, ctrl.name, ctrl.value);
                    ctrl.dirty_since = None;
                }
            }
        }
    }

    /// Reset all controls to driver defaults and apply immediately.
    pub fn reset_all(&mut self) {
        let device = self.device.clone();
        for ctrl in &mut self.ctrls {
            ctrl.value = ctrl.default;
            ctrl.dirty_since = None;
            fire_set_ctrl(&device, ctrl.name, ctrl.value);
        }
    }

    fn reset_one(&mut self, idx: usize) {
        let device = self.device.clone();
        let ctrl = &mut self.ctrls[idx];
        ctrl.value = ctrl.default;
        ctrl.dirty_since = None;
        fire_set_ctrl(&device, ctrl.name, ctrl.value);
    }

    /// Draw the 5-row slider panel. Call from MonitorPanel::show_input_panel.
    pub fn show_panel(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.heading("Input");
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.small_button("Reset All").clicked() {
                    self.reset_all();
                }
            });
        });
        ui.separator();

        // Two-pass: draw sliders, collect deferred actions to avoid borrow conflicts.
        let mut drag_stopped_idx: Option<(usize, i32)> = None;
        let mut reset_idx:        Option<usize>         = None;

        egui::Grid::new("v4l2_sliders")
            .num_columns(3)
            .spacing([6.0, 4.0])
            .show(ui, |ui| {
                for (i, ctrl) in self.ctrls.iter_mut().enumerate() {
                    ui.label(ctrl.label);
                    let resp = ui.add(
                        egui::Slider::new(&mut ctrl.value, ctrl.min..=ctrl.max)
                            .clamp_to_range(true),
                    );
                    if resp.changed() {
                        ctrl.dirty_since.get_or_insert_with(Instant::now);
                    }
                    if resp.drag_stopped() {
                        drag_stopped_idx = Some((i, ctrl.value));
                        ctrl.dirty_since = None;
                    }
                    if ui
                        .small_button("↺")
                        .on_hover_text(format!("Reset to {}", ctrl.default))
                        .clicked()
                    {
                        reset_idx = Some(i);
                    }
                    ui.end_row();
                }
            });

        // Apply deferred actions now that the per-ctrl mutable borrow has ended.
        if let Some((i, v)) = drag_stopped_idx {
            fire_set_ctrl(&self.device, self.ctrls[i].name, v);
        }
        if let Some(i) = reset_idx {
            self.reset_one(i);
        }
    }
}

// -----------------------------------------------------------------------
// Free helpers
// -----------------------------------------------------------------------

/// Spawn `v4l2-ctl -d DEV --set-ctrl=NAME=VALUE`, fire-and-forget.
fn fire_set_ctrl(device: &str, name: &str, value: i32) {
    let _ = std::process::Command::new("v4l2-ctl")
        .args(["-d", device, &format!("--set-ctrl={name}={value}")])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

/// Run `v4l2-ctl --list-ctrls` and parse current `value=N` for known controls.
/// Returns None if the command fails or produces no recognisable output.
fn query_values(device: &str) -> Option<BTreeMap<&'static str, i32>> {
    let out = std::process::Command::new("v4l2-ctl")
        .args(["-d", device, "--list-ctrls"])
        .output()
        .ok()?;

    let text = std::str::from_utf8(&out.stdout).ok()?;
    let mut map: BTreeMap<&'static str, i32> = BTreeMap::new();

    for line in text.lines() {
        // First whitespace-delimited token is the control name.
        let first = line.split_whitespace().next().unwrap_or("");
        if let Some((name, ..)) = DEFAULTS.iter().find(|(n, ..)| *n == first) {
            // The tail after the colon holds  "min=… max=… … value=N"
            if let Some(tail) = line.splitn(2, ':').nth(1) {
                for kv in tail.split_whitespace() {
                    if let Some(v_str) = kv.strip_prefix("value=") {
                        if let Ok(v) = v_str.parse::<i32>() {
                            map.insert(name, v);
                            break;
                        }
                    }
                }
            }
        }
    }

    if map.is_empty() { None } else { Some(map) }
}
