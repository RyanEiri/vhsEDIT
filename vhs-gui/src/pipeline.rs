use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Instant, SystemTime};

pub struct PipelineJob {
    child: Option<Child>,
    /// Human-readable label shown in the UI (e.g. "Stabilize seg001.mkv")
    pub label: String,
    /// True once the child has exited (success or failure).
    pub done: bool,
    pub current_frame: u64,
    /// 0 = unknown; progress bar is indeterminate.
    pub total_frames: u64,
    /// Directory where job log files are written (logs/).
    log_dir: PathBuf,
    /// Path to the log file we created for this job's stderr.
    script_log: Option<PathBuf>,
    started_at: Instant,
}

impl PipelineJob {
    /// Spawn a pipeline script.
    ///
    /// * `label`   – display name for the UI
    /// * `script`  – path to the bash script
    /// * `input`   – path passed as `$1` to the script
    /// * `envs`    – extra environment variables (e.g. `&[("NO_LAUNCH", "1")]`)
    /// * `log_dir` – `~/Videos/logs/` — where scripts write their own progress logs
    pub fn start(
        label: impl Into<String>,
        script: &Path,
        input: &Path,
        envs: &[(&str, &str)],
        extra_args: &[&str],
        log_dir: &Path,
    ) -> anyhow::Result<Self> {
        use std::os::unix::process::CommandExt as _;

        // Probe total frame count before spawning (fast: reads container header).
        let total_frames = probe_frames(input);

        let label_str: String = label.into();

        // Create a log file for this job; we redirect the child's stderr there
        // so we can tail it for ffmpeg "frame=" progress lines.
        // (Scripts don't write their own log files — ffmpeg output goes to stderr.)
        let slug: String = label_str
            .chars()
            .map(|c| if c.is_alphanumeric() || c == '-' { c } else { '_' })
            .take(40)
            .collect();
        let ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let log_path = log_dir.join(format!("{slug}_{ts}.log"));
        let log_file = fs::File::create(&log_path)?;

        let mut cmd = Command::new("bash");
        cmd.arg(script)
            .arg(input);
        for a in extra_args {
            cmd.arg(a);
        }
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            // Redirect stderr to our log file so we can tail frame= progress.
            .stderr(Stdio::from(log_file))
            .process_group(0); // own PGID so killpg() doesn't reach vhs-gui

        for (k, v) in envs {
            cmd.env(k, v);
        }

        let child = cmd.spawn()?;
        Ok(Self {
            child: Some(child),
            label: label_str,
            done: false,
            current_frame: 0,
            total_frames,
            log_dir: log_dir.to_path_buf(),
            script_log: Some(log_path),
            started_at: Instant::now(),
        })
    }

    /// Non-blocking poll: check child exit and tail the script's own log for
    /// frame progress.
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
        self.update_frame_count();
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

    /// Tail our stderr-redirect log file for ffmpeg `frame=` progress output.
    fn update_frame_count(&mut self) {
        let Some(ref log) = self.script_log else { return };

        let Ok(file) = fs::File::open(log) else { return };
        let reader = BufReader::new(file);

        // ffmpeg writes progress as `\r`-delimited runs within a single `\n`-line
        // (or as plain `\n`-lines when not a tty).  Split on both to be safe.
        let mut last_frame: Option<u64> = None;
        for raw_line in reader.lines().filter_map(|l| l.ok()) {
            for segment in raw_line.split('\r') {
                if segment.contains("frame=") {
                    if let Some(f) = parse_field(segment, "frame=") {
                        if let Ok(n) = f.parse::<u64>() {
                            last_frame = Some(n);
                        }
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

/// Estimate total frame count from container duration × frame rate.
/// Fast: reads only the container header/index, does not decode any frames.
/// Returns 0 on failure (progress bar will be indeterminate).
fn probe_frames(path: &Path) -> u64 {
    let out = Command::new("/usr/bin/ffprobe")
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=duration,r_frame_rate",
            "-of", "csv=p=0",
        ])
        .arg(path)
        .output();

    let Ok(out) = out else { return 0 };
    let s = String::from_utf8_lossy(&out.stdout);
    // CSV line: "duration,num/den"  e.g. "3672.100000,30000/1001"
    let mut parts = s.trim().split(',');
    let duration_s: f64 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
    let fps_str = parts.next().unwrap_or("0/1");
    let mut fps_parts = fps_str.split('/');
    let num: f64 = fps_parts.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
    let den: f64 = fps_parts.next().and_then(|s| s.parse().ok()).unwrap_or(1.0);
    if den == 0.0 || num == 0.0 || duration_s == 0.0 {
        return 0;
    }
    (duration_s * num / den).round() as u64
}
