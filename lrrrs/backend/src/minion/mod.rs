//! Minion: durable Postgres-backed job queue.

pub mod tasks;
pub mod worker;

use std::sync::Arc;

use std::path::Path;

use sqlx::PgPool;
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;

use tasks::Registry;

pub struct Controller {
    registry: Arc<Registry>,
    rayon: Arc<rayon::ThreadPool>,
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

impl Controller {
    /// Creates a controller whose registry includes pool-backed tasks
    /// (backup_json, restore_backup).
    pub fn new_with_pool(pool: PgPool, temp_dir: &Path, rayon: Arc<rayon::ThreadPool>) -> Self {
        Self {
            registry: Arc::new(Registry::with_pool(pool, temp_dir)),
            rayon,
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
        let rayon = self.rayon.clone();
        let handle = tokio::spawn(worker::run(pool, registry, rayon, cmd_rx));
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
