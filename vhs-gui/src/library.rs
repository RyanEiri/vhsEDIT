use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
pub enum FileKind {
    Archival,
    Stabilized,
    Viewer,
}

#[derive(Clone, Debug)]
pub struct LibraryEntry {
    pub path: PathBuf,
    pub name: String,
    pub kind: FileKind,
}

pub struct Library {
    pub entries: Vec<LibraryEntry>,
}

impl Library {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn refresh(&mut self, cfg: &crate::config::Config) {
        self.entries.clear();
        self.scan_dir(&cfg.viewer_dir(), FileKind::Viewer);
        self.scan_dir(&cfg.stabilized_dir(), FileKind::Stabilized);
        self.scan_dir(&cfg.archival_dir(), FileKind::Archival);
    }

    fn scan_dir(&mut self, dir: &std::path::Path, kind: FileKind) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        let mut entries: Vec<_> = rd
            .filter_map(|e| e.ok())
            .filter(|e| {
                let p = e.path();
                matches!(p.extension().and_then(|s| s.to_str()), Some("mkv" | "mp4"))
            })
            .collect();
        // Newest first
        entries.sort_by_key(|e| {
            std::cmp::Reverse(e.metadata().and_then(|m| m.modified()).ok())
        });
        for e in entries {
            let path = e.path();
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("?")
                .to_owned();
            self.entries.push(LibraryEntry { path, name, kind: kind.clone() });
        }
    }

    pub fn show(&self, ui: &mut egui::Ui) -> Option<LibraryEntry> {
        let mut selected = None;
        egui::ScrollArea::vertical().show(ui, |ui| {
            let mut last_kind = None;
            for entry in &self.entries {
                if last_kind.as_ref() != Some(&entry.kind) {
                    last_kind = Some(entry.kind.clone());
                    let label = match entry.kind {
                        FileKind::Viewer => "Viewer",
                        FileKind::Stabilized => "Stabilized",
                        FileKind::Archival => "Archival",
                    };
                    ui.separator();
                    ui.label(egui::RichText::new(label).small().weak());
                }
                if ui.selectable_label(false, &entry.name).clicked() {
                    selected = Some(entry.clone());
                }
            }
        });
        selected
    }
}

