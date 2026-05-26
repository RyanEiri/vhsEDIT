use std::fs;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

#[derive(Clone, Debug, Default)]
pub struct CaptureStats {
    pub frame: u64,
    pub time: String,
    pub bitrate: String,
    pub elapsed: Duration,
}

pub struct CaptureController {
    child: Option<Child>,
    pgid_file: PathBuf,
    archival_dir: PathBuf,
    log_file: Option<PathBuf>,
    started_at: Option<Instant>,
    started_sys: Option<SystemTime>,
    pub output_path: Option<PathBuf>,
    pub stats: Arc<Mutex<CaptureStats>>,
}

impl CaptureController {
    pub fn new(pgid_file: PathBuf, archival_dir: PathBuf) -> Self {
        Self {
            child: None,
            pgid_file,
            archival_dir,
            log_file: None,
            started_at: None,
            started_sys: None,
            output_path: None,
            stats: Arc::new(Mutex::new(CaptureStats::default())),
        }
    }

    pub fn is_running(&self) -> bool {
        self.child.is_some()
    }

    pub fn start(
        &mut self,
        script: &std::path::Path,
        max_duration: &str,
    ) -> anyhow::Result<()> {
        if self.child.is_some() {
            anyhow::bail!("capture already running");
        }
        // process_group(0) → setpgid(0,0) before exec, giving the child its
        // own process group (PGID == child's PID).  Without this, the child
        // inherits vhs-gui's PGID and killpg() would kill us too, causing an
        // ungraceful exit that corrupts KWin's EGL state.
        use std::os::unix::process::CommandExt as _;
        let child = Command::new("bash")
            .arg(script)
            .env("MAX_CAPTURE_DURATION", max_duration)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::inherit())
            .process_group(0)
            .spawn()?;
        self.started_at = Some(Instant::now());
        self.started_sys = Some(SystemTime::now());
        self.output_path = None;
        self.log_file = None;
        self.child = Some(child);
        Ok(())
    }

    /// Call periodically from the UI thread to collect child exit status and tail the log.
    pub fn poll(&mut self) {
        // Check if child exited
        if let Some(ref mut child) = self.child {
            match child.try_wait() {
                Ok(Some(_status)) => {
                    self.child = None;
                    self.started_at = None;
                }
                Ok(None) => {}
                Err(_) => {
                    self.child = None;
                }
            }
        }
        // Update elapsed
        if let Some(started) = self.started_at {
            if let Ok(mut s) = self.stats.lock() {
                s.elapsed = started.elapsed();
            }
        }
        // Discover the output file once it appears
        if self.output_path.is_none() {
            if let Some(sys) = self.started_sys {
                self.output_path = self.find_output_file(sys);
            }
        }
        // Tail the newest capture log
        if let Some(ref log) = self.log_file.clone() {
            self.tail_log(log);
        } else {
            self.log_file = self.find_newest_log();
        }
    }

    fn find_output_file(&self, after: SystemTime) -> Option<PathBuf> {
        std::fs::read_dir(&self.archival_dir)
            .ok()?
            .filter_map(|e| e.ok())
            .filter(|e| {
                matches!(
                    e.path().extension().and_then(|s| s.to_str()),
                    Some("mkv" | "mp4")
                )
            })
            .filter(|e| {
                e.metadata()
                    .and_then(|m| m.modified())
                    .map(|mtime| mtime >= after)
                    .unwrap_or(false)
            })
            .max_by_key(|e| e.metadata().and_then(|m| m.modified()).ok())
            .map(|e| e.path())
    }

    fn find_newest_log(&self) -> Option<PathBuf> {
        let log_dir = self.pgid_file.parent()?;
        std::fs::read_dir(log_dir)
            .ok()?
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("ffmpeg.log"))
            .max_by_key(|e| e.metadata().and_then(|m| m.modified()).ok())
            .map(|e| e.path())
    }

    fn tail_log(&self, log: &PathBuf) {
        let Ok(file) = fs::File::open(log) else { return };
        let reader = BufReader::new(file);
        let mut last_frame = 0u64;
        let mut last_time = String::new();
        let mut last_bitrate = String::new();
        let lines: Vec<_> = reader.lines().filter_map(|l| l.ok()).collect();
        for line in lines.iter().rev().take(20) {
            if line.contains("frame=") {
                if let Some(f) = parse_ffmpeg_field(line, "frame=") {
                    last_frame = f.parse().unwrap_or(0);
                }
                if let Some(t) = parse_ffmpeg_field(line, "time=") {
                    last_time = t.to_owned();
                }
                if let Some(b) = parse_ffmpeg_field(line, "bitrate=") {
                    last_bitrate = b.to_owned();
                }
                break;
            }
        }
        if let Ok(mut s) = self.stats.lock() {
            s.frame = last_frame;
            s.time = last_time;
            s.bitrate = last_bitrate;
        }
    }

    pub fn stop(&mut self) {
        self.send_sigint();
    }

    fn send_sigint(&self) {
        if let Ok(s) = fs::read_to_string(&self.pgid_file) {
            if let Ok(pgid) = s.trim().parse::<i32>() {
                use nix::sys::signal::{Signal, killpg};
                use nix::unistd::Pid;
                let _ = killpg(Pid::from_raw(pgid), Signal::SIGINT);
            }
        }
    }

    pub fn elapsed_str(&self) -> String {
        if let Some(started) = self.started_at {
            let d = started.elapsed();
            let h = d.as_secs() / 3600;
            let m = (d.as_secs() % 3600) / 60;
            let s = d.as_secs() % 60;
            format!("{h:02}:{m:02}:{s:02}")
        } else {
            "--:--:--".into()
        }
    }
}

fn parse_ffmpeg_field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let idx = line.find(key)?;
    let rest = &line[idx + key.len()..];
    Some(rest.split_whitespace().next().unwrap_or("").trim_end_matches('/'))
}
