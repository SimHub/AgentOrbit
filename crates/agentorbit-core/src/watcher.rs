use crate::paths::resolve_path;
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

/// Cross-platform filesystem watcher (FSEvents on macOS, inotify on Linux,
/// ReadDirectoryChangesW on Windows) with symlink resolution and debouncing.
pub struct OrbitWatcher {
    _watcher: RecommendedWatcher,
    rx: Receiver<notify::Result<Event>>,
    debounce: Duration,
    last_emit: Option<Instant>,
}

impl OrbitWatcher {
    pub fn start(paths: &[PathBuf], debounce: Duration) -> notify::Result<Self> {
        let (tx, rx) = mpsc::channel();
        let mut watcher = notify::recommended_watcher(move |res| {
            let _ = tx.send(res);
        })?;

        for path in paths {
            let resolved = resolve_path(path);
            if resolved.exists() {
                let mode = if resolved.is_dir() {
                    RecursiveMode::Recursive
                } else {
                    RecursiveMode::NonRecursive
                };
                let _ = watcher.watch(&resolved, mode);
            }
        }

        Ok(Self {
            _watcher: watcher,
            rx,
            debounce,
            last_emit: None,
        })
    }

    /// Blocks up to `timeout` waiting for a filesystem change, coalescing bursts
    /// within the configured debounce window. Returns `true` if a refresh is due.
    pub fn wait_for_change(&mut self, timeout: Duration) -> bool {
        match self.rx.recv_timeout(timeout) {
            Ok(Ok(_event)) => {
                // Drain queued burst events
                while self.rx.try_recv().is_ok() {}
                let now = Instant::now();
                if let Some(prev) = self.last_emit {
                    if now.duration_since(prev) < self.debounce {
                        return false;
                    }
                }
                self.last_emit = Some(now);
                true
            }
            _ => false,
        }
    }
}
