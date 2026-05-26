use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Instant;

pub struct PipelineJob {
    child: Option<Child>,
    /// Human-readable label shown in the UI (e.g. "Stabilize seg001.mkv")
    pub label: String,
    /// True once the child has exited (success or failure).
    pub done: bool,
    pub current_frame: u64,
    /// 0 = unknown; progress bar is indeterminate.
    pub total_frames: u64,
    log_path: PathBuf,
    started_at: Instant,
}

impl PipelineJob {
    /// Spawn a pipeline script.
    ///
    /// * `label`   – display name for the UI
    /// * `script`  – path to the bash script
    /// * `input`   – path passed as `$1` to the script
    /// * `envs`    – extra environment variables (e.g. `&[("NO_LAUNCH", "1")]`)
    /// * `log_dir` – where to write the stderr log
    pub fn start(
        label: impl Into<String>,
        script: &Path,
        input: &Path,
        envs: &[(&str, &str)],
        log_dir: &Path,
    ) -> anyhow::Result<Self> {
        use std::os::unix::process::CommandExt as _;

        let label = label.into();
        let ts = chrono_ts();
        let log_name = format!("{ts}_pipeline.log");
        let log_path = log_dir.join(&log_name);
        let log_file = fs::File::create(&log_path)?;

        // Best-effort: probe total frame count so we can show a real progress bar.
        let total_frames = probe_frames(input);

        let mut cmd = Command::new("bash");
        cmd.arg(script)
            .arg(input)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log_file)      // captured for tail
            .process_group(0);     // own PGID so killpg() doesn't reach vhs-gui

        for (k, v) in envs {
            cmd.env(k, v);
        }

        let child = cmd.spawn()?;
        Ok(Self {
            child: Some(child),
            label,
            done: false,
            current_frame: 0,
            total_frames,
            log_path,
            started_at: Instant::now(),
        })
    }

    /// Non-blocking poll: check child exit and tail log for frame progress.
    pub fn poll(&mut self) {
        if let Some(ref mut child) = self.child {
            match child.try_wait() {
                Ok(Some(_)) | Err(_) => {
                    self.child = None;
                    self.done = true;
                }
                Ok(None) => {}
            }
        } else {
            self.done = true;
        }
        self.tail_log();
    }

    pub fn is_running(&self) -> bool {
        self.child.is_some()
    }

    /// Fractional progress in `0.0..=1.0`.  Returns `None` when total is unknown.
    pub fn progress(&self) -> Option<f32> {
        if self.total_frames > 0 {
            Some((self.current_frame as f32 / self.total_frames as f32).min(1.0))
        } else {
            None
        }
    }

    pub fn elapsed_str(&self) -> String {
        let d = self.started_at.elapsed();
        let h = d.as_secs() / 3600;
        let m = (d.as_secs() % 3600) / 60;
        let s = d.as_secs() % 60;
        if h > 0 {
            format!("{h}:{m:02}:{s:02}")
        } else {
            format!("{m}:{s:02}")
        }
    }

    /// Send SIGINT to the child's process group.
    /// Safe because `.process_group(0)` makes child PGID == child PID.
    pub fn cancel(&self) {
        if let Some(ref child) = self.child {
            use nix::sys::signal::{Signal, killpg};
            use nix::unistd::Pid;
            let _ = killpg(Pid::from_raw(child.id() as i32), Signal::SIGINT);
        }
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    fn tail_log(&mut self) {
        let Ok(file) = fs::File::open(&self.log_path) else { return };
        let reader = BufReader::new(file);
        // Scan all lines; last `frame=` line wins.
        let mut last_frame = None;
        for line in reader.lines().filter_map(|l| l.ok()) {
            if line.contains("frame=") {
                if let Some(f) = parse_field(&line, "frame=") {
                    if let Ok(n) = f.parse::<u64>() {
                        last_frame = Some(n);
                    }
                }
            }
        }
        if let Some(f) = last_frame {
            self.current_frame = f;
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parse_field<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let idx = line.find(key)?;
    let rest = &line[idx + key.len()..];
    Some(rest.split_whitespace().next().unwrap_or("").trim_end_matches('/'))
}

/// Run ffprobe to get the frame count of a video file.  Returns 0 on failure.
fn probe_frames(path: &Path) -> u64 {
    let out = Command::new("/usr/bin/ffprobe")
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-count_packets",
            "-show_entries", "stream=nb_read_packets",
            "-of", "csv=p=0",
        ])
        .arg(path)
        .output();
    match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout)
            .trim()
            .parse::<u64>()
            .unwrap_or(0),
        Err(_) => 0,
    }
}

fn chrono_ts() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // yyyymmdd_HHMMSS approximation from unix timestamp
    let s = secs % 86400;
    let d = secs / 86400;
    // days since epoch → approximate date (good enough for log filenames)
    let h = s / 3600;
    let m = (s % 3600) / 60;
    let sec = s % 60;
    format!("{d}_{h:02}{m:02}{sec:02}")
}
