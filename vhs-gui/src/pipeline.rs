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
    /// Directory where scripts write their own log files (logs/).
    log_dir: PathBuf,
    /// Modification-time lower bound: only consider log files created after this.
    started_sys: SystemTime,
    /// Cached path to the script's own log file once discovered.
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
        log_dir: &Path,
    ) -> anyhow::Result<Self> {
        use std::os::unix::process::CommandExt as _;

        // Probe total frame count before spawning (fast: reads container header).
        let total_frames = probe_frames(input);

        let mut cmd = Command::new("bash");
        cmd.arg(script)
            .arg(input)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            // Inherit stderr so script errors appear in the terminal; the
            // scripts write their own progress logs via internal `tee` calls.
            .stderr(Stdio::inherit())
            .process_group(0); // own PGID so killpg() doesn't reach vhs-gui

        for (k, v) in envs {
            cmd.env(k, v);
        }

        let child = cmd.spawn()?;
        Ok(Self {
            child: Some(child),
            label: label.into(),
            done: false,
            current_frame: 0,
            total_frames,
            log_dir: log_dir.to_path_buf(),
            started_sys: SystemTime::now(),
            script_log: None,
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

    /// Discover and tail the script's own log file (written by the script's
    /// internal `tee` calls) for `frame=` progress output.
    fn update_frame_count(&mut self) {
        // Discover log file if not yet found.
        if self.script_log.is_none() {
            self.script_log = self.find_script_log();
        }
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

    /// Find the newest `.log` file in `log_dir` whose modification time is at
    /// or after `started_sys` — that's the log the running script is writing.
    fn find_script_log(&self) -> Option<PathBuf> {
        let after = self.started_sys;
        std::fs::read_dir(&self.log_dir)
            .ok()?
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.path().extension().and_then(|s| s.to_str()) == Some("log")
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
