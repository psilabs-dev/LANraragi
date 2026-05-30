//! Task trait + registry for the minion worker.
//!
//! CPU-bound work in task bodies must dispatch to the Rayon pool via
//! `support::cpu::run`; the trait passes a thread-pool handle for that purpose.

use std::collections::HashMap;
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::sync::Arc;

use serde_json::Value as JsonValue;
use sqlx::PgPool;

pub mod backup_json;
pub mod build_stat_hashes;
pub mod cover_thumbnail;
pub mod download_url;
pub mod noop;
pub mod page_thumbnail;
pub mod regen_thumbs;
pub mod restore_backup;
pub mod tank_thumbnail;

pub type TaskResult = Result<JsonValue, String>;
pub type TaskFuture<'a> = Pin<Box<dyn Future<Output = TaskResult> + Send + 'a>>;

pub trait Task: Send + Sync {
    fn name(&self) -> &'static str;
    fn run<'a>(&'a self, args: &'a JsonValue, rayon: &'a rayon::ThreadPool) -> TaskFuture<'a>;
}

#[derive(Default)]
pub struct Registry {
    by_name: HashMap<&'static str, Arc<dyn Task>>,
}

impl Registry {
    pub fn with_defaults() -> Self {
        let mut r = Self::default();
        r.register(Arc::new(noop::Noop));
        r.register(Arc::new(build_stat_hashes::BuildStatHashes));
        r.register(Arc::new(cover_thumbnail::CoverThumbnail));
        r.register(Arc::new(download_url::DownloadUrl));
        r.register(Arc::new(page_thumbnail::PageThumbnail));
        r.register(Arc::new(regen_thumbs::RegenThumbs));
        r.register(Arc::new(tank_thumbnail::TankThumbnail));
        r
    }

    /// All tasks, including pool-backed backup/restore tasks.
    pub fn with_pool(pool: PgPool, temp_dir: &Path) -> Self {
        let mut r = Self::with_defaults();
        r.register(Arc::new(backup_json::BackupJson {
            pool: pool.clone(),
            temp_dir: temp_dir.to_path_buf(),
        }));
        r.register(Arc::new(restore_backup::RestoreBackup { pool }));
        r
    }

    pub fn register(&mut self, task: Arc<dyn Task>) {
        self.by_name.insert(task.name(), task);
    }

    pub fn get(&self, name: &str) -> Option<Arc<dyn Task>> {
        self.by_name.get(name).cloned()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.by_name.contains_key(name)
    }
}

#[cfg(test)]
pub mod test_tasks {
    use serde_json::{Value as JsonValue, json};
    use super::{Task, TaskFuture};

    pub const PANIC_TASK_NAME: &str = "__test_panic__";
    pub const NOOP_TASK_NAME: &str = "noop";

    pub struct PanicTask;

    impl Task for PanicTask {
        fn name(&self) -> &'static str {
            PANIC_TASK_NAME
        }

        fn run<'a>(&'a self, _args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
            Box::pin(async move {
                panic!("PanicTask intentional panic for test");
            })
        }
    }

    pub struct ImmediateNoop;

    impl Task for ImmediateNoop {
        fn name(&self) -> &'static str {
            // Reuse noop NAME so it stays in the same task slot
            NOOP_TASK_NAME
        }

        fn run<'a>(&'a self, _args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
            Box::pin(async move {
                Ok(json!({ "echo": "immediate_noop" }))
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every externally-queueable task name must use the exact spelling from the
    /// `queueMinionJob` `jobname` enum in tools/openapi.yaml — aio-lanraragi enforces
    /// that contract, so a registry name that diverges makes the spec'd job type 400.
    /// Internal-only tasks (driven by dedicated endpoints) are exempt.
    #[test]
    fn registry_job_names_conform_to_openapi_enum() {
        const OPENAPI_JOBNAMES: &[&str] = &[
            "thumbnail_task",
            "tank_thumbnail_task",
            "page_thumbnails",
            "regen_all_thumbnails",
            "find_duplicates",
            "build_stat_hashes",
            "handle_upload",
            "download_url",
            "run_plugin",
        ];
        const INTERNAL_ONLY: &[&str] = &["noop", "backup_json", "restore_backup"];

        let registry = Registry::with_defaults();
        for name in registry.by_name.keys().copied() {
            assert!(
                OPENAPI_JOBNAMES.contains(&name) || INTERNAL_ONLY.contains(&name),
                "registered minion task `{name}` is neither a queueMinionJob enum value \
                 nor a documented internal-only task (see tools/openapi.yaml)"
            );
        }
    }
}
