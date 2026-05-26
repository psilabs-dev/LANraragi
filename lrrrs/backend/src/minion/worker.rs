//! Worker loop: claim, dispatch, transition.

use std::sync::Arc;
use std::time::Duration;

use sqlx::PgPool;
use tokio::sync::mpsc;
use tokio::time::sleep;
use tracing::{error, info, warn};

use super::tasks::Registry;
use crate::db;

const POLL_INTERVAL: Duration = Duration::from_millis(500);

pub enum Cmd {
    Stop,
}

pub async fn run(pool: PgPool, registry: Arc<Registry>, mut cmd_rx: mpsc::Receiver<Cmd>) {
    loop {
        tokio::select! {
            cmd = cmd_rx.recv() => match cmd {
                None | Some(Cmd::Stop) => break,
            },
            _ = sleep(POLL_INTERVAL) => {
                if let Err(error) = poll_once(&pool, &registry).await {
                    warn!(?error, "minion poll failed");
                }
            }
        }
    }
}

async fn poll_once(pool: &PgPool, registry: &Registry) -> Result<(), sqlx::Error> {
    let Some(job) = db::jobs::claim_next(pool).await? else {
        return Ok(());
    };
    let Some(task) = registry.get(&job.task) else {
        let msg = format!("no handler registered for task `{}`", job.task);
        warn!(id = job.id, task = %job.task, "{msg}");
        return db::jobs::mark_failed(pool, job.id, &msg).await;
    };
    info!(id = job.id, task = %job.task, "minion: running");
    match task.run(&job.args).await {
        Ok(notes) => db::jobs::mark_finished(pool, job.id, &notes).await,
        Err(reason) => {
            error!(id = job.id, task = %job.task, reason, "minion: task failed");
            db::jobs::mark_failed(pool, job.id, &reason).await
        }
    }
}
