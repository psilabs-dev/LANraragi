//! Restore-from-backup task.
//!
//! Accepts a JSON string as its sole argument (`args[0]`), parses it,
//! and calls `service::backup::restore_from_json`.

use serde_json::{Value as JsonValue, json};
use sqlx::PgPool;

use super::{Task, TaskFuture};

pub const NAME: &str = "restore_backup";

pub struct RestoreBackup {
    pub pool: PgPool,
}

impl Task for RestoreBackup {
    fn name(&self) -> &'static str {
        NAME
    }
    fn run<'a>(&'a self, args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            let json_str = args
                .get(0)
                .and_then(JsonValue::as_str)
                .ok_or_else(|| "restore_backup: missing args[0] (backup JSON string)".to_string())?;

            let backup: JsonValue =
                serde_json::from_str(json_str).map_err(|e| e.to_string())?;

            crate::service::backup::restore_from_json(&self.pool, &backup)
                .await
                .map_err(|e| e.to_string())?;

            Ok(json!({ "restored": true }))
        })
    }
}
