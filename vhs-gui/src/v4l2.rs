use std::collections::BTreeMap;
use std::ffi::CString;

// VIDIOC_G_CTRL = _IOWR('V', 27, struct v4l2_control) = 0xC008_561B
// VIDIOC_S_CTRL = _IOWR('V', 28, struct v4l2_control) = 0xC008_561C
// Derived: _IOC(READ|WRITE=3, 'V'=0x56, nr, sizeof(v4l2_control)=8)
//   = (3<<30) | (0x56<<8) | nr | (8<<16)
const VIDIOC_G_CTRL: libc::c_ulong = 0xC008_561B;
const VIDIOC_S_CTRL: libc::c_ulong = 0xC008_561C;

#[repr(C)]
struct V4l2CtrlReq {
    id:    u32,
    value: i32,
}

pub struct V4l2Control {
    pub name:    &'static str,
    pub label:   &'static str,
    pub min:     i32,
    pub max:     i32,
    pub default: i32,
    pub value:   i32,
}

pub struct V4l2Controls {
    pub ctrls:  Vec<V4l2Control>,
    /// File descriptor kept open for the lifetime of V4l2Controls so that
    /// VIDIOC_S_CTRL is a ~5 µs ioctl rather than a fork+exec.  -1 = unavailable.
    ctrl_fd:    libc::c_int,
}

// (name, label, min, max, default, V4L2_CID)
static DEFAULTS: &[(&str, &str, i32, i32, i32, u32)] = &[
    ("brightness", "Brightness", 0, 255, 25,  0x00980900),
    ("contrast",   "Contrast",   0, 255, 127, 0x00980901),
    ("saturation", "Saturation", 0, 255, 127, 0x00980902),
    ("hue",        "Hue",        0, 127, 0,   0x00980903),
    ("gamma",      "Gamma",      0, 50,  0,   0x00980910),
];

impl V4l2Controls {
    pub fn new(device: &str) -> Self {
        // Open the device fd once and keep it for all subsequent ioctls.
        let ctrl_fd = CString::new(device)
            .map(|c| unsafe { libc::open(c.as_ptr(), libc::O_RDWR) })
            .unwrap_or(-1);

        let mut ctrls: Vec<V4l2Control> = DEFAULTS
            .iter()
            .map(|(name, label, min, max, default, _cid)| V4l2Control {
                name, label, min: *min, max: *max, default: *default, value: *default,
            })
            .collect();

        // Read actual current values from the driver via VIDIOC_G_CTRL.
        if ctrl_fd >= 0 {
            for (ctrl, (_, _, _, _, _, cid)) in ctrls.iter_mut().zip(DEFAULTS) {
                let mut req = V4l2CtrlReq { id: *cid, value: 0 };
                let ret = unsafe { libc::ioctl(ctrl_fd, VIDIOC_G_CTRL, &mut req) };
                if ret == 0 {
                    ctrl.value = req.value.clamp(ctrl.min, ctrl.max);
                }
            }
        }

        Self { ctrls, ctrl_fd }
    }

    /// Snapshot current control values as a name→value map for persistence.
    pub fn to_preset(&self) -> BTreeMap<String, i32> {
        self.ctrls.iter().map(|c| (c.name.to_owned(), c.value)).collect()
    }

    /// Apply a name→value map to controls and issue VIDIOC_S_CTRL for each.
    pub fn apply_values(&mut self, preset: &BTreeMap<String, i32>) {
        for ctrl in &mut self.ctrls {
            if let Some(&v) = preset.get(ctrl.name) {
                ctrl.value = v.clamp(ctrl.min, ctrl.max);
            }
        }
        // Fire ioctls after the mutable loop ends so there's no borrow conflict.
        let fd = self.ctrl_fd;
        for (ctrl, (_, _, _, _, _, cid)) in self.ctrls.iter().zip(DEFAULTS) {
            ioctl_set(fd, *cid, ctrl.value);
        }
    }

    /// Reset all controls to driver defaults and apply immediately.
    pub fn reset_all(&mut self) {
        let fd = self.ctrl_fd;
        for (ctrl, (_, _, _, _, _, cid)) in self.ctrls.iter_mut().zip(DEFAULTS) {
            ctrl.value = ctrl.default;
            ioctl_set(fd, *cid, ctrl.value);
        }
    }

    fn reset_one(&mut self, idx: usize) {
        let fd = self.ctrl_fd;
        let (ctrl, (_, _, _, _, _, cid)) = (&mut self.ctrls[idx], &DEFAULTS[idx]);
        ctrl.value = ctrl.default;
        ioctl_set(fd, *cid, ctrl.value);
    }

    /// Draw the 5-row slider panel. Returns true if any value changed this frame.
    pub fn show_panel(&mut self, ui: &mut egui::Ui) -> bool {
        ui.horizontal(|ui| {
            ui.heading("Input");
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.small_button("Reset All").clicked() {
                    self.reset_all();
                }
            });
        });
        ui.separator();

        // Collect (cid, value) pairs inside the Grid closure (where self.ctrls is
        // mutably borrowed), then fire ioctls after the borrow ends.
        let mut fires: Vec<(u32, i32)> = Vec::new();
        let mut reset_idx: Option<usize> = None;

        egui::Grid::new("v4l2_sliders")
            .num_columns(3)
            .spacing([6.0, 4.0])
            .show(ui, |ui| {
                for (i, (ctrl, (_, _, _, _, _, cid))) in
                    self.ctrls.iter_mut().zip(DEFAULTS).enumerate()
                {
                    ui.label(ctrl.label);
                    let resp = ui.add(
                        egui::Slider::new(&mut ctrl.value, ctrl.min..=ctrl.max)
                            .clamp_to_range(true),
                    );
                    if resp.changed() {
                        fires.push((*cid, ctrl.value));
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

        let changed = !fires.is_empty() || reset_idx.is_some();
        let fd = self.ctrl_fd;
        for (cid, value) in fires {
            ioctl_set(fd, cid, value);
        }
        if let Some(i) = reset_idx {
            self.reset_one(i);
        }
        changed
    }
}

impl Drop for V4l2Controls {
    fn drop(&mut self) {
        if self.ctrl_fd >= 0 {
            unsafe { libc::close(self.ctrl_fd); }
        }
    }
}

// -----------------------------------------------------------------------
// Free helpers
// -----------------------------------------------------------------------

/// Issue VIDIOC_S_CTRL on an already-open fd. No-op if fd < 0.
/// Takes ~5 µs; zero allocation, zero process spawning.
fn ioctl_set(fd: libc::c_int, cid: u32, value: i32) {
    if fd < 0 { return; }
    let req = V4l2CtrlReq { id: cid, value };
    unsafe { libc::ioctl(fd, VIDIOC_S_CTRL, &req as *const V4l2CtrlReq); }
}
