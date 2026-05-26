//! Shinobu: filesystem watcher and periodic rescan lifecycle.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;

/// Owned by `AppState`; lifecycle handle for the watcher task.
pub struct Controller {
    inner: Arc<Mutex<Inner>>,
}

struct Inner {
    state: TaskState,
    pid: u32,
}

enum TaskState {
    Running {
        handle: JoinHandle<()>,
        cmd_tx: mpsc::Sender<Cmd>,
    },
    Stopped,
}

enum Cmd {
    Stop,
    #[allow(dead_code)]
    Rescan,
}

impl Default for Controller {
    fn default() -> Self {
        Self::new()
    }
}

impl Controller {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                state: TaskState::Stopped,
                pid: 0,
            })),
        }
    }

    /// Starts the watcher task if not already running. Returns the (possibly
    /// existing) pid.
    pub async fn start(&self) -> u32 {
        let mut inner = self.inner.lock().await;
        if let TaskState::Running { .. } = inner.state {
            return inner.pid;
        }
        inner.pid = inner.pid.wrapping_add(1);
        let (cmd_tx, cmd_rx) = mpsc::channel(8);
        let handle = tokio::spawn(run_watcher(cmd_rx));
        inner.state = TaskState::Running { handle, cmd_tx };
        inner.pid
    }

    /// Stops the watcher task. No-op if already stopped.
    pub async fn stop(&self) {
        let mut inner = self.inner.lock().await;
        let prev = std::mem::replace(&mut inner.state, TaskState::Stopped);
        if let TaskState::Running { handle, cmd_tx } = prev {
            let _ = cmd_tx.send(Cmd::Stop).await;
            let _ = handle.await;
        }
    }

    /// Stops + starts. Returns the new pid.
    pub async fn restart(&self) -> u32 {
        self.stop().await;
        self.start().await
    }

    /// Restarts the watcher. Filemap truncation is not yet implemented;
    /// behaves identically to `restart`.
    pub async fn rescan(&self) -> u32 {
        self.restart().await
    }

    /// Returns `(is_alive, pid)`.
    pub async fn status(&self) -> (bool, u32) {
        let inner = self.inner.lock().await;
        let alive = matches!(inner.state, TaskState::Running { .. });
        (alive, inner.pid)
    }
}

async fn run_watcher(mut cmd_rx: mpsc::Receiver<Cmd>) {
    loop {
        tokio::select! {
            cmd = cmd_rx.recv() => {
                match cmd {
                    None | Some(Cmd::Stop) => break,
                    Some(Cmd::Rescan) => {}
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(300)) => {}
        }
    }
}
