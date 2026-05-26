//! Minion: durable Postgres-backed job queue.

pub mod tasks;
pub mod worker;

use std::sync::Arc;

use sqlx::PgPool;
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;

use tasks::Registry;

pub struct Controller {
    registry: Arc<Registry>,
    inner: Mutex<Inner>,
}

struct Inner {
    state: TaskState,
}

enum TaskState {
    Running {
        handle: JoinHandle<()>,
        cmd_tx: mpsc::Sender<worker::Cmd>,
    },
    Stopped,
}

impl Default for Controller {
    fn default() -> Self {
        Self::new()
    }
}

impl Controller {
    pub fn new() -> Self {
        Self {
            registry: Arc::new(Registry::with_defaults()),
            inner: Mutex::new(Inner {
                state: TaskState::Stopped,
            }),
        }
    }

    /// Spawns the worker task if not already running.
    pub async fn start(&self, pool: PgPool) {
        let mut inner = self.inner.lock().await;
        if let TaskState::Running { .. } = inner.state {
            return;
        }
        let (cmd_tx, cmd_rx) = mpsc::channel(8);
        let registry = self.registry.clone();
        let handle = tokio::spawn(worker::run(pool, registry, cmd_rx));
        inner.state = TaskState::Running { handle, cmd_tx };
    }

    /// Signals the worker to stop and awaits its exit. No-op if already stopped.
    pub async fn stop(&self) {
        let mut inner = self.inner.lock().await;
        let prev = std::mem::replace(&mut inner.state, TaskState::Stopped);
        if let TaskState::Running { handle, cmd_tx } = prev {
            let _ = cmd_tx.send(worker::Cmd::Stop).await;
            let _ = handle.await;
        }
    }

    pub fn known_task(&self, name: &str) -> bool {
        self.registry.contains(name)
    }
}
