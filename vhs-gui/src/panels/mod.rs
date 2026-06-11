pub mod monitor;
pub mod upscale;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ViewMode {
    Monitor,
    Upscale,
}

impl Default for ViewMode {
    fn default() -> Self {
        Self::Monitor
    }
}
