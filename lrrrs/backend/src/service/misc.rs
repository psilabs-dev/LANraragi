//! Misc business logic (server info, temp folder, URL download, thumb regen).

use sqlx::PgPool;

use crate::auth::LrrConfig;
use crate::db;
use crate::minion;
use crate::minion::tasks::{download_url, regen_thumbs};
use crate::openapi::types::ServerInfo;
use crate::support::url::validate_download_url;
pub async fn build_server_info(pool: &PgPool, config: &LrrConfig, excluded_namespaces_raw: &str) -> Result<ServerInfo, sqlx::Error> {
    let total_archives = db::archive::count(pool).await?;
    // server_tracks_progress: true when the server owns progress (localprogress disabled).
    let server_tracks_progress = !config.localprogress;
    let excluded_namespaces: Vec<String> = excluded_namespaces_raw
        .split(',')
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    Ok(ServerInfo {
        name: "LANraragi".into(),
        motd: String::new(),
        version: env!("CARGO_PKG_VERSION").into(),
        version_name: "LRRRS".into(),
        version_desc: "Rust rewrite of LANraragi".into(),
        has_password: db::api_key::load_hash(pool).await?.is_some(),
        debug_mode: false,
        nofun_mode: config.nofunmode,
        archives_per_page: i64::from(config.pagesize),
        server_resizes_images: false,
        server_tracks_progress,
        authenticated_progress: config.authprogress,
        total_pages_read: 0,
        total_archives,
        cache_last_cleared: 0,
        excluded_namespaces,
    })
}

#[derive(Debug)]
pub enum CleanTempError {
    Io(std::io::Error),
}

impl std::fmt::Display for CleanTempError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "io error: {e}"),
        }
    }
}

impl std::error::Error for CleanTempError {}

impl From<CleanTempError> for crate::error::PendingApiError {
    fn from(e: CleanTempError) -> Self {
        crate::error::PendingApiError::internal(e.to_string())
    }
}

/// Removes all files under the temp directory.
///
/// Returns the number of entries removed. Mirrors Perl's
/// `LANraragi::Utils::PageCache::clear` which calls `rmtree` on the temp dir.
///
pub async fn clean_tempfolder(temp_dir: &std::path::Path) -> Result<u64, CleanTempError> {
    if !temp_dir.exists() {
        return Ok(0);
    }

    let mut count: u64 = 0;
    let mut read_dir = tokio::fs::read_dir(temp_dir)
        .await
        .map_err(CleanTempError::Io)?;

    while let Some(entry) = read_dir.next_entry().await.map_err(CleanTempError::Io)? {
        let path = entry.path();
        if path.is_dir() {
            tokio::fs::remove_dir_all(&path)
                .await
                .map_err(CleanTempError::Io)?;
        } else {
            tokio::fs::remove_file(&path)
                .await
                .map_err(CleanTempError::Io)?;
        }
        count += 1;
    }

    Ok(count)
}

/// Enqueues a `download_url` minion job.
///
/// Returns the new job id.
///
pub async fn enqueue_download_url(
    pool: &PgPool,
    controller: &minion::Controller,
    url: &str,
    catid: Option<&str>,
) -> Result<i64, crate::error::PendingApiError> {
    validate_download_url(url).await.map_err(crate::error::PendingApiError::from)?;
    // TODO(ssrf): revalidate after HTTP redirects when the task fetch is implemented.
    let args_raw = serde_json::json!([url, catid]).to_string();
    super::minion::enqueue(pool, controller, download_url::NAME, &args_raw, 1)
        .await
        .map_err(crate::error::PendingApiError::from)
}

/// Enqueues a `regen_thumbs` minion job.
///
/// Returns the new job id.
///
pub async fn enqueue_regen_thumbnails(
    pool: &PgPool,
    controller: &minion::Controller,
    thumb_dir: &std::path::Path,
    force: bool,
) -> Result<i64, super::minion::EnqueueError> {
    let args_raw = serde_json::json!([thumb_dir.to_string_lossy(), force]).to_string();
    super::minion::enqueue(pool, controller, regen_thumbs::NAME, &args_raw, 0).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_temp_on_missing_dir_returns_zero() {
        // A non-existent path should short-circuit to Ok(0) without error,
        // mirroring LRR's rmtree(temp/) behavior on an already-empty dir.
        let rt = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let result = rt.block_on(clean_tempfolder(std::path::Path::new(
            "/tmp/lrrrs_nonexistent_test_dir_should_not_exist_7f3a",
        )));
        assert_eq!(result.unwrap(), 0);
    }
}
