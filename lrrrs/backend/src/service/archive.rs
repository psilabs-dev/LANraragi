//! Archive business logic.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::json;
use sqlx::PgPool;
use tracing::warn;

use crate::db;
use crate::openapi::types::{
    ArchiveMetadataJson, ArchiveMetadataJsonArcid, ArchiveMetadataJsonIsnew,
};
use crate::support::archive::{self, ProbeError};
use crate::support::filesystem;

pub async fn list_all(pool: &PgPool) -> Result<Vec<ArchiveMetadataJson>, sqlx::Error> {
    let rows = db::archive::list_all(pool).await?;
    Ok(rows.into_iter().map(into_dto).collect())
}

fn into_dto(r: db::archive::ArchiveRow) -> ArchiveMetadataJson {
    let title = if r.title.trim().is_empty() {
        r.filename.clone()
    } else {
        r.title
    };
    // DB-stored arcids are validated SHA-1 hex on insert; this parse cannot fail
    // for rows already in `lrr_archive`. Panics here would indicate corruption.
    let arcid = ArchiveMetadataJsonArcid::try_from(r.arcid)
        .expect("lrr_archive.arcid violates the arcid pattern; database is corrupt");
    ArchiveMetadataJson {
        arcid,
        title,
        filename: r.filename,
        tags: r.tags,
        summary: r.summary,
        isnew: if r.isnew {
            ArchiveMetadataJsonIsnew::True
        } else {
            ArchiveMetadataJsonIsnew::False
        },
        extension: r.extension.unwrap_or_default(),
        progress: i64::from(r.progress),
        pagecount: i64::from(r.pagecount),
        lastreadtime: i64::from(r.lastreadtime),
        size: r.arcsize.unwrap_or(0),
        toc: Vec::new(),
    }
}

#[derive(Debug)]
pub enum UploadError {
    BadChecksum(String),
    BadArchive(String),
    Duplicate,
    Io(std::io::Error),
    Db(sqlx::Error),
}

impl std::fmt::Display for UploadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadChecksum(why) => write!(f, "checksum rejected: {why}"),
            Self::BadArchive(why) => write!(f, "archive rejected: {why}"),
            Self::Duplicate => write!(f, "archive already exists"),
            Self::Io(e) => write!(f, "io error: {e}"),
            Self::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

impl std::error::Error for UploadError {}

impl From<UploadError> for crate::error::PendingApiError {
    fn from(e: UploadError) -> Self {
        use crate::error::PendingApiError;
        match e {
            UploadError::BadChecksum(why) | UploadError::BadArchive(why) => {
                PendingApiError::bad_request(why)
            }
            UploadError::Duplicate => PendingApiError::conflict("archive already exists"),
            UploadError::Io(io) => PendingApiError::internal(io.to_string()),
            UploadError::Db(db) => PendingApiError::internal(db.to_string()),
        }
    }
}

pub struct UploadInput {
    pub temp_path: PathBuf,
    pub arcid: String,
    pub user_filename: String,
    pub file_checksum: Option<String>,
    pub title: Option<String>,
    pub summary: Option<String>,
    pub arcsize: i64,
}

/// Move a streamed, hashed temp file into the content root, register it in the
/// database, and enqueue cover-thumbnail generation. Returns the arcid on
/// success. The caller is responsible for cleaning up `temp_path` on error.
pub async fn upload(
    pool: &PgPool,
    rayon: &Arc<rayon::ThreadPool>,
    content_dir: &Path,
    input: UploadInput,
) -> Result<String, UploadError> {
    if let Some(expected) = input.file_checksum.as_deref()
        && !expected.eq_ignore_ascii_case(&input.arcid)
    {
        return Err(UploadError::BadChecksum(format!(
            "client-supplied checksum {expected} does not match server hash {arcid}",
            arcid = input.arcid
        )));
    }

    if db::archive::exists(pool, &input.arcid)
        .await
        .map_err(UploadError::Db)?
    {
        return Err(UploadError::Duplicate);
    }

    let probe = archive::probe(rayon, input.temp_path.clone())
        .await
        .map_err(|e| match e {
            ProbeError::NotZip
            | ProbeError::EmptyArchive
            | ProbeError::Zip(_)
            | ProbeError::Worker(_) => UploadError::BadArchive(e.to_string()),
            ProbeError::Io(io) => UploadError::Io(io),
        })?;

    let final_path = filesystem::resolve_upload_target(content_dir, &input.user_filename);
    let final_path_str = final_path
        .to_str()
        .ok_or_else(|| UploadError::BadArchive("upload path is not valid UTF-8".into()))?
        .to_string();

    if tokio::fs::try_exists(&final_path)
        .await
        .map_err(UploadError::Io)?
    {
        return Err(UploadError::Duplicate);
    }

    tokio::fs::rename(&input.temp_path, &final_path)
        .await
        .map_err(UploadError::Io)?;

    let extension = filesystem::extension(&input.user_filename);
    let title = input
        .title
        .as_deref()
        .filter(|t| !t.trim().is_empty())
        .map_or_else(|| derive_title(&input.user_filename), str::to_string);

    let mut tx = pool.begin().await.map_err(UploadError::Db)?;
    db::archive::insert(
        &mut *tx,
        &db::archive::NewArchive {
            arcid: &input.arcid,
            filename: &input.user_filename,
            extension: extension.as_deref(),
            title: &title,
            summary: input.summary.as_deref().filter(|s| !s.is_empty()),
            pagecount: i32::try_from(probe.pagecount).unwrap_or(i32::MAX),
            arcsize: input.arcsize,
        },
    )
    .await
    .map_err(UploadError::Db)?;
    db::filemap::insert(&mut *tx, &final_path_str, &input.arcid)
        .await
        .map_err(UploadError::Db)?;
    tx.commit().await.map_err(UploadError::Db)?;

    let enqueue_result =
        db::jobs::insert(pool, "cover_thumbnail", &json!([&input.arcid]), 0).await;
    if let Err(error) = enqueue_result {
        warn!(arcid = %input.arcid, ?error, "failed to enqueue cover thumbnail");
    }

    Ok(input.arcid)
}

fn derive_title(filename: &str) -> String {
    Path::new(filename)
        .file_stem()
        .and_then(|os| os.to_str())
        .unwrap_or(filename)
        .to_string()
}
