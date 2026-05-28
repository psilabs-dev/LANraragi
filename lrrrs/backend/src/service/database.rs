//! Database business logic.

use serde_json::{Value as JsonValue, json};
use sqlx::PgPool;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info, warn};

use crate::auth::VerifyCache;
use crate::db;
use crate::service;

#[derive(Debug)]
pub enum DatabaseError {
    Db(sqlx::Error),
    JobNotFinished(String),
    BackupPathMissing,
}

impl std::fmt::Display for DatabaseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Db(e) => write!(f, "db error: {e}"),
            Self::JobNotFinished(state) => write!(f, "job not completed yet (state: {state})"),
            Self::BackupPathMissing => write!(f, "backup file not available"),
        }
    }
}

impl std::error::Error for DatabaseError {}

impl From<DatabaseError> for crate::error::PendingApiError {
    fn from(e: DatabaseError) -> Self {
        match e {
            DatabaseError::Db(_) => crate::error::PendingApiError::internal(e.to_string()),
            DatabaseError::JobNotFinished(_) => crate::error::PendingApiError::bad_request(e.to_string()),
            DatabaseError::BackupPathMissing => crate::error::PendingApiError::bad_request(e.to_string()),
        }
    }
}

/// Walks all archive rows, deletes those whose backing file is missing, then
/// removes orphan tag rows.  Returns `(deleted, unlinked)`.
///
/// `unlinked` is always 0: the rename-reconciliation pass
/// (`change_archive_id_with_dbh`) is not yet implemented.
// TODO: implement ID-reconciliation pass (Perl change_archive_id_with_dbh).
pub async fn clean_database(pool: &PgPool) -> Result<(u64, u64), DatabaseError> {
    // Fetch (arcid, filename) pairs from lrr_archive.
    let rows = db::archive::list_paths_for_clean(pool)
        .await
        .map_err(DatabaseError::Db)?;

    let mut deleted: u64 = 0;

    for (arcid, filename) in rows {
        // Archives with an empty filename are already unlinked; skip.
        if filename.is_empty() {
            continue;
        }

        let exists = tokio::fs::try_exists(&filename).await.unwrap_or(false);
        if !exists {
            debug!(arcid, filename, "archive file missing; deleting archive row");
            match service::archive::delete_archive(pool, &arcid).await {
                Ok(_) => {
                    info!(arcid, "deleted missing-file archive");
                    deleted += 1;
                }
                Err(e) => {
                    warn!(arcid, error = %e, "failed to delete archive during clean");
                }
            }
        }
    }

    // Remove tag rows no longer referenced by any archive mapping.
    db::backup::delete_orphan_tags(pool)
        .await
        .map_err(DatabaseError::Db)?;

    Ok((deleted, 0))
}
pub async fn clear_isnew_all(pool: &PgPool) -> Result<(), DatabaseError> {
    db::backup::clear_isnew_all(pool)
        .await
        .map_err(DatabaseError::Db)?;
    Ok(())
}

/// Deletes all archives and all dependent rows (filemap, category maps,
/// tank maps, tag maps, toc, stamps). Also deletes the API key row and
/// invalidates in-memory auth state.
///
/// Archive deletion and API key deletion run in a single transaction so that
/// a partial failure cannot leave archives gone while the API key survives.
pub async fn drop_database(
    pool: &PgPool,
    api_key_hash: &Arc<RwLock<Option<Arc<str>>>>,
    verify_cache: &VerifyCache,
) -> Result<(), DatabaseError> {
    let mut tx = pool.begin().await.map_err(DatabaseError::Db)?;
    db::backup::drop_all_archives(&mut *tx)
        .await
        .map_err(DatabaseError::Db)?;
    db::api_key::delete_all(&mut *tx)
        .await
        .map_err(DatabaseError::Db)?;
    tx.commit().await.map_err(DatabaseError::Db)?;
    *api_key_hash.write().await = None;
    verify_cache.clear().await;
    Ok(())
}

/// Fetches the file-system path of a completed backup job.
///
/// Returns `Ok(None)` when the job does not exist.
/// Returns `Err` when the job exists but has not finished, or when the
/// `notes.path` field is absent.
pub async fn get_backup_path(pool: &PgPool, jobid: i64) -> Result<Option<String>, DatabaseError> {
    let row = crate::db::jobs::fetch(pool, jobid)
        .await
        .map_err(DatabaseError::Db)?;
    let row = match row {
        None => return Ok(None),
        Some(r) => r,
    };
    if row.state != "finished" {
        return Err(DatabaseError::JobNotFinished(row.state));
    }
    let path = row.notes["path"]
        .as_str()
        .ok_or(DatabaseError::BackupPathMissing)?
        .to_owned();
    Ok(Some(path))
}

/// Returns tag statistics as a JSON array:
/// `[{"namespace": "...", "text": "...", "weight": N}, ...]`
///
/// `minweight` defaults to 1.  `excluded_namespaces` is an optional
/// comma-separated list of namespaces to suppress.
pub async fn get_statistics(
    pool: &PgPool,
    minweight: i64,
    excluded_namespaces: &[String],
) -> Result<Vec<JsonValue>, DatabaseError> {
    let rows = db::backup::get_tag_stats(pool, minweight, excluded_namespaces)
        .await
        .map_err(DatabaseError::Db)?;

    let stats = rows
        .into_iter()
        .filter(|r| !r.value.is_empty())
        .map(|r| {
            json!({
                "namespace": r.namespace,
                "text":      r.value,
                "weight":    r.weight,
            })
        })
        .collect();

    Ok(stats)
}
