//! Backup JSON generation task.
//!
//! Builds the backup JSON and writes it to a temp file.  The finished-job
//! `notes` field carries `{"path": "<absolute path>"}` so that
//! `downloadBackup` can locate the file.

use std::path::PathBuf;

use serde_json::{Value as JsonValue, json};
use sqlx::PgPool;
use tokio::io::AsyncWriteExt;
use tracing::info;

use super::{Task, TaskFuture};

pub const NAME: &str = "backup_json";

pub struct BackupJson {
    pub pool: PgPool,
    pub temp_dir: PathBuf,
}

impl Task for BackupJson {
    fn name(&self) -> &'static str {
        NAME
    }
    fn run<'a>(&'a self, _args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            let backup = crate::service::backup::build_backup_json(&self.pool)
                .await
                .map_err(|e| e.to_string())?;

            let json_bytes = serde_json::to_vec(&backup).map_err(|e| e.to_string())?;

            // Write to a unique temp file under config.temp_dir so that
            // cleanTempfolder can sweep it and concurrent backup jobs cannot collide.
            let path = self.temp_dir.join(format!(
                "lrr-backup-{}.json",
                uuid::Uuid::new_v4()
            ));

            let mut file = tokio::fs::File::create(&path)
                .await
                .map_err(|e| e.to_string())?;
            file.write_all(&json_bytes)
                .await
                .map_err(|e| e.to_string())?;
            file.flush().await.map_err(|e| e.to_string())?;
            file.sync_all().await.map_err(|e| e.to_string())?;

            let path_str = path.to_string_lossy().to_string();
            info!("backup_json: wrote {path_str}");

            Ok(json!({ "path": path_str }))
        })
    }
}
