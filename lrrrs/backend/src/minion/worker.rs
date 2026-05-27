//! Worker loop: claim, dispatch, transition.
//!
//! Design constraints: a single worker task runs the poll
//! loop; at most one job is claimed and awaited per 500 ms tick, so long-running jobs (backup,
//! regen_thumbs) starve all other queued work for their duration.  There is no per-task timeout
//! and no automatic retry on transient failure; a failed job is marked `failed` once with no
//! re-enqueue path.

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

pub async fn run(pool: PgPool, registry: Arc<Registry>, rayon: Arc<rayon::ThreadPool>, mut cmd_rx: mpsc::Receiver<Cmd>) {
    loop {
        tokio::select! {
            cmd = cmd_rx.recv() => match cmd {
                None | Some(Cmd::Stop) => break,
            },
            _ = sleep(POLL_INTERVAL) => {
                if let Err(error) = poll_once(&pool, &registry, Arc::clone(&rayon)).await {
                    warn!(?error, "minion poll failed");
                }
            }
        }
    }
}

async fn poll_once(pool: &PgPool, registry: &Registry, rayon: Arc<rayon::ThreadPool>) -> Result<(), sqlx::Error> {
    let Some(job) = db::jobs::claim_next(pool).await? else {
        return Ok(());
    };
    let Some(task) = registry.get(&job.task) else {
        let msg = format!("no handler registered for task `{}`", job.task);
        warn!(id = job.id, task = %job.task, "{msg}");
        return db::jobs::mark_failed(pool, job.id, &msg).await;
    };
    info!(id = job.id, task = %job.task, "minion: running");
    let id = job.id;
    let task_name = job.task.clone();
    let args = job.args.clone();
    let join = tokio::spawn(async move { task.run(&args, &rayon).await });
    match join.await {
        Ok(Ok(notes)) => db::jobs::mark_finished(pool, id, &notes).await,
        Ok(Err(reason)) => {
            error!(id, task = %task_name, reason, "minion: task failed");
            db::jobs::mark_failed(pool, id, &reason).await
        }
        Err(join_err) if join_err.is_panic() => {
            let msg = format!("task panicked: {:?}", join_err);
            error!(id, task = %task_name, "minion: task panicked; marking failed");
            db::jobs::mark_failed(pool, id, &msg).await
        }
        Err(join_err) => {
            let msg = format!("task join error: {join_err}");
            error!(id, task = %task_name, "minion: task join error");
            db::jobs::mark_failed(pool, id, &msg).await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::minion::tasks::test_tasks;
    use serde_json::json;
    use std::sync::Arc;

    /// Verifies that a panic inside a task future does not kill the worker
    /// and that a subsequent noop task still completes.
    ///
    /// Requires a live Postgres DB; skipped otherwise.
    #[tokio::test]
    #[ignore = "requires live Postgres DB (TEST_DATABASE_URL)"]
    async fn panic_task_does_not_kill_worker() {
        let db_url = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
        let pool = sqlx::PgPool::connect(&db_url).await.unwrap();
        crate::db::migrate::run(&pool).await.unwrap();

        // Register PanicTask + Noop in a fresh registry.
        let rayon = Arc::new(
            rayon::ThreadPoolBuilder::new()
                .num_threads(1)
                .build()
                .unwrap(),
        );
        let mut registry = crate::minion::tasks::Registry::default();
        registry.register(Arc::new(test_tasks::PanicTask));
        registry.register(Arc::new(test_tasks::ImmediateNoop));
        let registry = Arc::new(registry);

        // Insert panic job then noop job.
        let panic_id = db::jobs::insert(&pool, test_tasks::PANIC_TASK_NAME, &json!([]), 1)
            .await
            .unwrap();
        let noop_id = db::jobs::insert(&pool, test_tasks::NOOP_TASK_NAME, &json!([]), 1)
            .await
            .unwrap();

        // Run two poll cycles (one per job).
        poll_once(&pool, &registry, Arc::clone(&rayon)).await.unwrap();
        poll_once(&pool, &registry, Arc::clone(&rayon)).await.unwrap();

        let panic_row = db::jobs::fetch(&pool, panic_id).await.unwrap().unwrap();
        let noop_row = db::jobs::fetch(&pool, noop_id).await.unwrap().unwrap();

        assert_eq!(panic_row.state, "failed", "panic task must be marked failed");
        assert_eq!(noop_row.state, "finished", "noop task must complete after panic task");
    }
}
