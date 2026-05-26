use std::path::PathBuf;

pub struct Config {
    pub videos_dir: PathBuf,
    pub v4l2_device: String,
    pub max_capture_duration: String,
    pub capture_script: PathBuf,
}

impl Default for Config {
    fn default() -> Self {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/home/ryan".into()));
        let videos = home.join("Videos");
        Self {
            capture_script: videos.join("vhs_capture_ffmpeg.sh"),
            v4l2_device: "/dev/v4l/by-id/usb-MACROSIL_AV_TO_USB2.0-video-index0".into(),
            max_capture_duration: "04:00:00".into(),
            videos_dir: videos,
        }
    }
}

impl Config {
    pub fn archival_dir(&self) -> PathBuf {
        self.videos_dir.join("captures/archival")
    }
    pub fn stabilized_dir(&self) -> PathBuf {
        self.videos_dir.join("captures/stabilized")
    }
    pub fn viewer_dir(&self) -> PathBuf {
        self.videos_dir.join("captures/viewer")
    }
    pub fn log_dir(&self) -> PathBuf {
        self.videos_dir.join("logs")
    }
    pub fn capture_pgid_file(&self) -> PathBuf {
        self.log_dir().join("capture.pgid")
    }
    pub fn stabilize_script(&self) -> PathBuf {
        self.videos_dir.join("vhs_stabilize.sh")
    }
    pub fn process_script(&self) -> PathBuf {
        self.videos_dir.join("vhs_process.sh")
    }
    pub fn ivtc_script(&self) -> PathBuf {
        self.videos_dir.join("vhs_ivtc.sh")
    }
}
