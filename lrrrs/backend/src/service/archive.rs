//! Archive business logic.

use std::fs::File;
use std::io::{BufReader, Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use serde_json::json;
use sqlx::PgPool;
use tracing::warn;

use crate::db;
use crate::openapi::types::{
    ArchiveMetadataJson, ArchiveMetadataJsonArcid, ArchiveMetadataJsonIsnew,
};
use crate::service::thumbnail;
use crate::support::archive::{self, ProbeError};
use crate::support::filesystem;
pub async fn list_all(pool: &PgPool) -> Result<Vec<ArchiveMetadataJson>, sqlx::Error> {
    let rows = db::archive::list_all(pool).await?;

    // Batch-fetch all toc entries in one query to avoid N+1.
    let arcids: Vec<String> = rows.iter().map(|r| r.arcid.clone()).collect();
    let toc_rows = db::archive::list_tocs_for_arcids(pool, &arcids).await?;

    // Build a per-arcid toc map.
    let mut toc_map: std::collections::HashMap<String, Vec<serde_json::Value>> =
        std::collections::HashMap::new();
    for t in toc_rows {
        toc_map
            .entry(t.arcid)
            .or_default()
            .push(serde_json::json!({"page": t.page, "name": t.title}));
    }

    // Batch-fetch filemap paths and drop archives whose backing file is absent.
    // Mirrors PgArchive.pm:71-72: `next unless (defined($file) && -e $file)`.
    let path_rows = db::archive::list_paths_for_arcids(pool, &arcids).await?;
    let mut path_map: std::collections::HashMap<String, String> =
        path_rows.into_iter().collect();

    let mut result = Vec::with_capacity(rows.len());
    for r in rows {
        let Some(path) = path_map.remove(&r.arcid) else {
            // No filemap entry: treat as missing.
            continue;
        };
        if !tokio::fs::try_exists(&path).await.unwrap_or(false) {
            continue;
        }
        let toc = toc_map.remove(&r.arcid).unwrap_or_default();
        result.push(row_into_dto(r, toc));
    }

    Ok(result)
}

pub(crate) fn row_into_dto(
    r: db::archive::ArchiveRow,
    toc: Vec<serde_json::Value>,
) -> ArchiveMetadataJson {
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
        // Coerce None to Some("") so the field is always serialized on the wire.
        summary: Some(r.summary.unwrap_or_default()),
        // isnew serializes as "true"/"false" strings per openapi.yaml; not a JSON boolean.
        isnew: if r.isnew {
            ArchiveMetadataJsonIsnew::True
        } else {
            ArchiveMetadataJsonIsnew::False
        },
        extension: r.extension.unwrap_or_default(),
        progress: i64::from(r.progress),
        pagecount: i64::from(r.pagecount),
        lastreadtime: r.lastreadtime,
        size: r.arcsize.unwrap_or(0),
        toc,
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
    pub tags: Option<String>,
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

    let pagecount_upload = i32::try_from(probe.pagecount)
        .map_err(|_| UploadError::BadArchive("archive pagecount overflows i32".into()))?;

    let mut tx = pool.begin().await.map_err(UploadError::Db)?;
    db::lock::lock_archive_write(&mut *tx, &input.arcid)
        .await
        .map_err(UploadError::Db)?;
    db::archive::insert(
        &mut *tx,
        &db::archive::NewArchive {
            arcid: &input.arcid,
            filename: &input.user_filename,
            extension: extension.as_deref(),
            title: &title,
            summary: input.summary.as_deref().filter(|s| !s.is_empty()),
            pagecount: pagecount_upload,
            arcsize: input.arcsize,
        },
    )
    .await
    .map_err(UploadError::Db)?;
    db::filemap::insert(&mut *tx, &final_path_str, &input.arcid)
        .await
        .map_err(UploadError::Db)?;
    if let Some(tags_str) = input.tags.as_deref().filter(|s| !s.is_empty()) {
        db::archive::set_tags(&mut tx, &input.arcid, tags_str.trim())
            .await
            .map_err(UploadError::Db)?;
    }
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

#[derive(Debug)]
pub enum ArchiveError {
    NotFound(String),
    BadRequest(String),
    Db(sqlx::Error),
    Io(std::io::Error),
}

impl std::fmt::Display for ArchiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound(msg) => write!(f, "{msg}"),
            Self::BadRequest(msg) => write!(f, "{msg}"),
            Self::Db(e) => write!(f, "db error: {e}"),
            Self::Io(e) => write!(f, "io error: {e}"),
        }
    }
}

impl std::error::Error for ArchiveError {}

impl From<ArchiveError> for crate::error::PendingApiError {
    fn from(e: ArchiveError) -> Self {
        use crate::error::PendingApiError;
        match e {
            // openapi declares 400 only; matches Perl render_api_response behavior
            ArchiveError::NotFound(msg) => PendingApiError::bad_request(msg),
            ArchiveError::BadRequest(msg) => PendingApiError::bad_request(msg),
            ArchiveError::Db(db) => PendingApiError::internal(db.to_string()),
            ArchiveError::Io(io) => PendingApiError::internal(io.to_string()),
        }
    }
}
pub async fn get_metadata(
    pool: &PgPool,
    arcid: &str,
) -> Result<ArchiveMetadataJson, ArchiveError> {
    let row = db::archive::get_one(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
        .ok_or_else(|| ArchiveError::NotFound("This ID doesn't exist on the server.".into()))?;
    let toc_rows = db::archive::list_toc(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?;
    let toc = toc_rows
        .into_iter()
        .map(|t| serde_json::json!({"page": t.page, "name": t.title}))
        .collect();
    Ok(row_into_dto(row, toc))
}
pub async fn get_categories(pool: &PgPool, arcid: &str) -> Result<Vec<crate::service::category::CategoryDto>, ArchiveError> {
    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound(
            "This ID doesn't exist on the server.".into(),
        ));
    }
    let catids = db::archive::list_categories_for_archive(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?;
    let mut result = Vec::with_capacity(catids.len());
    for catid in &catids {
        if let Some(dto) = crate::service::category::get(pool, catid)
            .await
            .map_err(ArchiveError::Db)?
        {
            result.push(dto);
        }
    }
    Ok(result)
}
pub async fn get_tankoubons(pool: &PgPool, arcid: &str) -> Result<Vec<String>, ArchiveError> {
    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound(
            "This ID doesn't exist on the server.".into(),
        ));
    }
    db::archive::list_tankoubons_for_archive(pool, arcid)
        .await
        .map_err(ArchiveError::Db)
}
pub async fn list_untagged(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    db::archive::list_untagged(pool).await
}

pub struct FilesResult {
    pub pages: Vec<String>,
}

/// Extracts archive pages on first call (cached to disk in `temp/<arcid>/`).
/// Returns URL-encoded page paths for `/api/archives/:id/page?path=...`.
/// Lazy extract, cached forever. Re-extract only when `force=true`.
pub async fn get_files(
    pool: &PgPool,
    rayon: &Arc<rayon::ThreadPool>,
    temp_dir: &Path,
    arcid: &str,
    force: bool,
) -> Result<FilesResult, ArchiveError> {
    let archive_path = db::archive::get_path(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
        .ok_or_else(|| ArchiveError::NotFound("Archive not found.".into()))?;

    let extract_dir = thumbnail::temp_extract_dir(temp_dir, arcid);

    // Serve from cache when available and not forced.
    if !force && tokio::fs::try_exists(&extract_dir).await.map_err(ArchiveError::Io)? {
        if let Ok(cached) = read_extract_dir(&extract_dir).await {
            if !cached.is_empty() {
                let pages = build_page_urls(arcid, &cached);
                return Ok(FilesResult { pages });
            }
        }
    }

    let archive_path_buf = PathBuf::from(archive_path);
    let extract_dir_clone = extract_dir.clone();
    let entries = crate::support::cpu::run(rayon, move || {
        extract_archive_blocking(&archive_path_buf, &extract_dir_clone)
    })
    .await
    .map_err(|e| ArchiveError::Io(std::io::Error::other(e.to_string())))?
    .map_err(ArchiveError::Io)?;

    let pagecount = i32::try_from(entries.len())
        .map_err(|_| ArchiveError::BadRequest("extracted pagecount overflows i32".into()))?;
    if let Err(e) = db::archive::update_pagecount(pool, arcid, pagecount).await {
        warn!(arcid, ?e, "failed to update pagecount after extraction");
    }

    let pages = build_page_urls(arcid, &entries);
    Ok(FilesResult { pages })
}

/// Serves a single extracted page from the temp dir.
pub async fn get_page_bytes(
    temp_dir: &Path,
    arcid: &str,
    path: &str,
) -> Result<Vec<u8>, ArchiveError> {
    // Sanitize: extract the basename only. Extraction already flattens all
    // entries to bare filenames, so only a basename is ever valid here. Any
    // traversal component in `path` is stripped, and an empty result
    // (e.g. path was ".." or "/") is rejected.
    let basename = std::path::Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| ArchiveError::BadRequest("Invalid page path.".into()))?;

    let page_path = thumbnail::temp_extract_dir(temp_dir, arcid).join(basename);

    tokio::fs::read(&page_path).await.map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            ArchiveError::NotFound(format!("Page not found: {path}"))
        } else {
            ArchiveError::Io(e)
        }
    })
}
pub async fn set_isnew(pool: &PgPool, arcid: &str, isnew: bool) -> Result<(), ArchiveError> {
    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound("Archive not found.".into()));
    }
    let mut tx = pool.begin().await.map_err(ArchiveError::Db)?;
    db::lock::lock_archive_write(&mut *tx, arcid)
        .await
        .map_err(ArchiveError::Db)?;
    db::archive::set_isnew(&mut *tx, arcid, isnew)
        .await
        .map_err(ArchiveError::Db)?;
    tx.commit().await.map_err(ArchiveError::Db)
}

/// Updates reading progress. Returns `(page, lastreadtime_epoch)`.
/// Bounds validation (page in [1, pagecount]) happens inside the DB transaction
/// before the UPDATE, so an out-of-range page never commits.
pub async fn update_progress(
    pool: &PgPool,
    arcid: &str,
    page: i32,
) -> Result<(i32, i64), ArchiveError> {
    let time = i64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before Unix epoch is not supported")
            .as_secs(),
    )
    .expect("Unix epoch seconds overflow i64");

    let mut tx = pool.begin().await.map_err(ArchiveError::Db)?;
    db::lock::lock_archive_write(&mut *tx, arcid)
        .await
        .map_err(ArchiveError::Db)?;

    use db::archive::UpdateProgressOutcome;
    let outcome = db::archive::update_progress_in_tx(&mut tx, arcid, page, time)
        .await
        .map_err(ArchiveError::Db)?;
    tx.commit().await.map_err(ArchiveError::Db)?;

    match outcome {
        UpdateProgressOutcome::NotFound => {
            Err(ArchiveError::NotFound("Archive not found.".into()))
        }
        UpdateProgressOutcome::OutOfRange(pagecount) => Err(ArchiveError::BadRequest(format!(
            "Invalid progress value: page {page} out of range [1, {pagecount}]"
        ))),
        UpdateProgressOutcome::Ok(final_page, lastreadtime) => Ok((final_page, lastreadtime)),
    }
}

/// Updates archive metadata. At least one of title/tags/summary must be Some.
/// Returns a success message including the final title.
pub async fn update_metadata(
    pool: &PgPool,
    arcid: &str,
    title: Option<&str>,
    tags: Option<&str>,
    summary: Option<&str>,
) -> Result<String, ArchiveError> {
    if title.is_none() && tags.is_none() {
        return Err(ArchiveError::BadRequest(
            "No metadata parameters (Please supply title, tags or summary)".into(),
        ));
    }

    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound("Archive not found.".into()));
    }

    let mut tx = pool.begin().await.map_err(ArchiveError::Db)?;
    db::lock::lock_archive_write(&mut *tx, arcid)
        .await
        .map_err(ArchiveError::Db)?;

    if let Some(t) = title {
        db::archive::set_title(&mut *tx, arcid, t.trim())
            .await
            .map_err(ArchiveError::Db)?;
    }

    if let Some(tg) = tags {
        db::archive::set_tags(&mut tx, arcid, tg.trim())
            .await
            .map_err(ArchiveError::Db)?;
    }

    if let Some(s) = summary {
        db::archive::set_summary(&mut *tx, arcid, s)
            .await
            .map_err(ArchiveError::Db)?;
    }

    tx.commit().await.map_err(ArchiveError::Db)?;

    let final_title = db::archive::get_title(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
        .ok_or_else(|| ArchiveError::NotFound("Archive disappeared post-commit.".into()))?;

    Ok(format!("Updated metadata for \"{final_title}\"!"))
}

/// Deletes an archive from DB and filesystem.
/// Returns the deleted file path string (empty if file was absent).
pub async fn delete_archive(pool: &PgPool, arcid: &str) -> Result<String, ArchiveError> {
    let file_path = db::archive::get_path(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?;

    // Confirm existence even if filemap row is missing.
    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound("Archive not found.".into()));
    }

    let mut tx = pool.begin().await.map_err(ArchiveError::Db)?;
    db::lock::lock_archive_write(&mut *tx, arcid)
        .await
        .map_err(ArchiveError::Db)?;
    db::archive::delete(&mut tx, arcid)
        .await
        .map_err(ArchiveError::Db)?;
    tx.commit().await.map_err(ArchiveError::Db)?;

    // Best-effort file deletion after commit.
    if let Some(ref path_str) = file_path {
        let p = Path::new(path_str);
        if let Err(e) = tokio::fs::remove_file(p).await {
            if e.kind() != std::io::ErrorKind::NotFound {
                warn!(arcid, path = %path_str, ?e, "failed to remove archive file");
            }
        }
    }

    Ok(file_path.unwrap_or_default())
}
pub async fn add_toc(
    pool: &PgPool,
    arcid: &str,
    page: i32,
    title: &str,
) -> Result<(), ArchiveError> {
    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound("Archive not found.".into()));
    }
    let mut tx = pool.begin().await.map_err(ArchiveError::Db)?;
    db::lock::lock_archive_write(&mut *tx, arcid)
        .await
        .map_err(ArchiveError::Db)?;
    db::archive::upsert_toc(&mut *tx, arcid, page, title)
        .await
        .map_err(ArchiveError::Db)?;
    tx.commit().await.map_err(ArchiveError::Db)
}
pub async fn delete_toc(pool: &PgPool, arcid: &str, page: i32) -> Result<(), ArchiveError> {
    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound("Archive not found.".into()));
    }
    let mut tx = pool.begin().await.map_err(ArchiveError::Db)?;
    db::lock::lock_archive_write(&mut *tx, arcid)
        .await
        .map_err(ArchiveError::Db)?;
    db::archive::delete_toc(&mut *tx, arcid, page)
        .await
        .map_err(ArchiveError::Db)?;
    tx.commit().await.map_err(ArchiveError::Db)
}

/// Returns the on-disk archive path for downloading.
pub async fn get_file_path(pool: &PgPool, arcid: &str) -> Result<PathBuf, ArchiveError> {
    db::archive::get_path(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
        .map(PathBuf::from)
        .ok_or_else(|| ArchiveError::NotFound("Archive not found.".into()))
}

/// Thumbnail result: raw bytes (200) or a queued job id (202).
pub enum ThumbnailResult {
    Bytes(Vec<u8>),
    Queued(i64),
}

/// Serves the cover (or per-page) thumbnail.
/// - Thumbnail exists: returns 200 bytes.
/// - `no_fallback=true` + thumbnail missing: enqueue job, return job id (202).
/// - `no_fallback=false` + thumbnail missing: return 1x1 placeholder.
pub async fn get_thumbnail(
    pool: &PgPool,
    thumb_dir: &Path,
    arcid: &str,
    page: Option<u32>,
    no_fallback: bool,
) -> Result<ThumbnailResult, ArchiveError> {
    if !db::archive::exists(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
    {
        return Err(ArchiveError::NotFound("Archive not found.".into()));
    }

    let thumb_path = match page {
        None | Some(0) => thumbnail::cover_thumb_path(thumb_dir, arcid),
        Some(n) => thumbnail::page_thumb_path(thumb_dir, arcid, n),
    };

    if tokio::fs::try_exists(&thumb_path)
        .await
        .map_err(ArchiveError::Io)?
    {
        let bytes = tokio::fs::read(&thumb_path).await.map_err(ArchiveError::Io)?;
        return Ok(ThumbnailResult::Bytes(bytes));
    }

    if no_fallback {
        // For per-page thumbnails (page >= 1), enqueue page_thumbnails with
        // [arcid, page, force=false] (single-page, no force).
        // For cover thumbnails (page 0/None), enqueue cover_thumbnail.
        let job_id = match page {
            Some(n) if n >= 1 => {
                db::jobs::insert(pool, "page_thumbnails", &json!([arcid, n, false]), 0).await
            }
            _ => db::jobs::insert(pool, "cover_thumbnail", &json!([arcid]), 0).await,
        }
        .map_err(ArchiveError::Db)?;
        return Ok(ThumbnailResult::Queued(job_id));
    }

    // Return a minimal 1×1 transparent WebP as placeholder.
    Ok(ThumbnailResult::Bytes(placeholder_webp()))
}

/// Regenerates the cover thumbnail from a specific page.
/// Output is WebP. Supported source formats: JPEG, PNG, WebP, GIF.
pub async fn update_thumbnail(
    pool: &PgPool,
    rayon: &Arc<rayon::ThreadPool>,
    thumb_dir: &Path,
    arcid: &str,
    page: u32,
) -> Result<String, ArchiveError> {
    let archive_path = db::archive::get_path(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
        .ok_or_else(|| ArchiveError::NotFound("Archive not found.".into()))?;

    let thumb_path = thumbnail::cover_thumb_path(thumb_dir, arcid);
    let sub_dir = thumb_dir.join(&arcid[..2]);
    tokio::fs::create_dir_all(&sub_dir)
        .await
        .map_err(ArchiveError::Io)?;

    let archive_path_buf = PathBuf::from(archive_path);
    let thumb_path_clone = thumb_path.clone();
    crate::support::cpu::run(rayon, move || {
        extract_and_write_thumb_blocking(&archive_path_buf, &thumb_path_clone, page)
    })
    .await
    .map_err(|e| ArchiveError::Io(std::io::Error::other(e.to_string())))?
    .map_err(ArchiveError::Io)?;

    Ok(thumb_path.to_string_lossy().into_owned())
}

/// Queues per-page thumbnail generation if any thumbnails are missing.
/// Returns `None` (200) if all exist, `Some(job_id)` (202) if a job was queued.
pub async fn queue_page_thumbnails(
    pool: &PgPool,
    thumb_dir: &Path,
    arcid: &str,
    force: bool,
) -> Result<Option<i64>, ArchiveError> {
    let (_, pagecount) = db::archive::get_path_and_pagecount(pool, arcid)
        .await
        .map_err(ArchiveError::Db)?
        .ok_or_else(|| ArchiveError::NotFound("Archive not found.".into()))?;

    let needs_job = if force {
        true
    } else {
        let mut missing = false;
        for pg in 1..=pagecount {
            let p = thumbnail::page_thumb_path(
                thumb_dir,
                arcid,
                u32::try_from(pg).unwrap_or(0),
            );
            if !tokio::fs::try_exists(&p).await.map_err(ArchiveError::Io)? {
                missing = true;
                break;
            }
        }
        missing
    };

    if !needs_job {
        return Ok(None);
    }

    // Batch: page=0 means all pages. [arcid, page, force] matches page_thumbnails task shape.
    let job_id = db::jobs::insert(pool, "page_thumbnails", &json!([arcid, 0, force]), 0)
        .await
        .map_err(ArchiveError::Db)?;

    Ok(Some(job_id))
}

async fn read_extract_dir(dir: &Path) -> std::io::Result<Vec<String>> {
    let mut entries = Vec::new();
    let mut rd = tokio::fs::read_dir(dir).await?;
    while let Some(entry) = rd.next_entry().await? {
        let name = entry.file_name().to_string_lossy().into_owned();
        if is_image_filename(&name) {
            entries.push(name);
        }
    }
    entries.sort();
    Ok(entries)
}

fn build_page_urls(arcid: &str, entries: &[String]) -> Vec<String> {
    entries
        .iter()
        .map(|name| {
            let encoded = utf8_percent_encode(name, NON_ALPHANUMERIC)
                .to_string()
                .replace("%2F", "/");
            format!("/api/archives/{arcid}/page?path={encoded}")
        })
        .collect()
}

const IMAGE_EXTS: &[&str] = &["jpg", "jpeg", "png", "webp", "gif"];

fn is_image_filename(name: &str) -> bool {
    let ext = name.rsplit('.').next().map(str::to_ascii_lowercase);
    matches!(ext, Some(e) if IMAGE_EXTS.contains(&e.as_str()))
}
//
// Zero-pads every digit run to 10 characters and lowercases, producing a sort
// key that matches Perl's natural sort order.
fn natural_sort_key(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    let mut i = 0;
    let bytes = s.as_bytes();
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            let run = &s[start..i];
            // Pad to 10 digits (Perl uses %04d; we use 10 to be safe with any
            // real-world page count).
            let _ = std::fmt::write(&mut out, format_args!("{:0>10}", run));
        } else {
            out.push((bytes[i] as char).to_ascii_lowercase());
            i += 1;
        }
    }
    out
}
//
// Sorts `names` with natural ordering, then rotates cover pages to the front
// and credit/note pages to the end, mirroring Perl's get_filelist behaviour.
fn sort_filelist(names: &mut Vec<String>) {
    names.sort_by(|a, b| natural_sort_key(a).cmp(&natural_sort_key(b)));

    // Cover: matches /cover/i but NOT if path also matches back|end|rear|recover|discover.
    // Credit: matches credit, notes.*, note.*, artist_info, end_card_save_file, 999...
    // Perl regresses apply to the full path (basename in our case since we strip dirs).
    let is_cover = |n: &str| {
        let lower = n.to_ascii_lowercase();
        lower.contains("cover")
            && !["back", "end", "rear", "recover", "discover"]
                .iter()
                .any(|bad| lower.contains(bad))
    };
    // Perl: /^end_card_save_file|notes\.[^\.]*$|note\.[^\.]*$|^artist_info|credit|^999.*/i
    let is_credit = |n: &str| {
        let lower = n.to_ascii_lowercase();
        lower.starts_with("end_card_save_file")
            || lower.starts_with("artist_info")
            || lower.starts_with("999")
            || lower.contains("credit")
            || lower.starts_with("notes.")
            || lower.starts_with("note.")
    };

    let covers: Vec<String> = names.iter().filter(|n| is_cover(n)).cloned().collect();
    let credits: Vec<String> = names.iter().filter(|n| is_credit(n)).cloned().collect();
    let others: Vec<String> = names
        .iter()
        .filter(|n| !is_cover(n) && !is_credit(n))
        .cloned()
        .collect();

    names.clear();
    names.extend(covers);
    names.extend(others);
    names.extend(credits);
}

// Blocking: extracts all image entries from a ZIP archive into `dest_dir`.
fn extract_archive_blocking(
    archive_path: &Path,
    dest_dir: &Path,
) -> std::io::Result<Vec<String>> {
    use std::fs;

    fs::create_dir_all(dest_dir)?;

    let file = File::open(archive_path)?;
    let reader = BufReader::new(file);
    let mut zip =
        zip::ZipArchive::new(reader).map_err(|e| std::io::Error::other(e.to_string()))?;

    let mut names = Vec::new();

    for i in 0..zip.len() {
        let mut entry = zip
            .by_index(i)
            .map_err(|e| std::io::Error::other(e.to_string()))?;

        if entry.is_dir() {
            continue;
        }

        let raw_name = entry.name().to_string();
        let base = Path::new(&raw_name)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| raw_name.clone());

        if !is_image_filename(&base) {
            continue;
        }

        let dest = dest_dir.join(&base);
        let mut out = File::create(&dest)?;
        std::io::copy(&mut entry, &mut out)?;
        names.push(base);
    }

    sort_filelist(&mut names);
    Ok(names)
}

// Blocking: extracts `page` (1-indexed) from archive and writes WebP to `dest`.
// Supported source formats: JPEG, PNG, WebP, GIF; output WebP.
fn extract_and_write_thumb_blocking(
    archive_path: &Path,
    dest: &Path,
    page: u32,
) -> std::io::Result<()> {
    let file = File::open(archive_path)?;
    let reader = BufReader::new(file);
    let mut zip =
        zip::ZipArchive::new(reader).map_err(|e| std::io::Error::other(e.to_string()))?;

    // Collect (basename, full_zip_path) pairs; sort by basename with natural
    // ordering to match extract_archive_blocking.
    let mut image_entries: Vec<(String, String)> = (0..zip.len())
        .filter_map(|i| {
            let e = zip.by_index_raw(i).ok()?;
            if e.is_dir() {
                return None;
            }
            let full = e.name().to_string();
            let base = Path::new(&full)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| full.clone());
            if is_image_filename(&base) {
                Some((base, full))
            } else {
                None
            }
        })
        .collect();
    // Sort basenames with natural ordering + cover/credit rotation, then
    // reorder image_entries to match.
    let mut basenames: Vec<String> = image_entries.iter().map(|(b, _)| b.clone()).collect();
    sort_filelist(&mut basenames);
    image_entries.sort_by_key(|(base, _)| {
        basenames.iter().position(|b| b == base).unwrap_or(usize::MAX)
    });

    let idx = if page == 0 {
        0
    } else {
        (page as usize).saturating_sub(1)
    };
    let (_, target_full) = image_entries
        .get(idx)
        .ok_or_else(|| std::io::Error::other(format!("page {page} not found in archive")))?;

    let mut entry = zip
        .by_name(target_full)
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    let mut buf = Vec::new();
    entry.read_to_end(&mut buf)?;

    let fmt = image::ImageFormat::from_path(target_full).unwrap_or(image::ImageFormat::Jpeg);
    let img = image::load(Cursor::new(&buf), fmt)
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    img.save_with_format(dest, image::ImageFormat::WebP)
        .map_err(|e| std::io::Error::other(e.to_string()))
}

/// Minimal 1×1 transparent WebP placeholder (26 bytes).
pub(crate) fn placeholder_webp() -> Vec<u8> {
    vec![
        0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00, // RIFF....
        0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c, // WEBPVP8L
        0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00, // ..../...
        0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0x08, // ........
        0x08, 0x00, // ..
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    // R2-01: natural sort key mirrors Perl expand() — digit-padding + case-fold.
    #[test]
    fn natural_sort_key_pads_digits() {
        // Digit runs must be zero-padded to 10 chars so numeric order beats
        // lexicographic order.
        assert!(natural_sort_key("page2.jpg") < natural_sort_key("page10.jpg"));
        assert!(natural_sort_key("page1.jpg") < natural_sort_key("page2.jpg"));
    }

    #[test]
    fn natural_sort_key_is_case_insensitive() {
        assert_eq!(natural_sort_key("Cover.jpg"), natural_sort_key("cover.jpg"));
        assert_eq!(natural_sort_key("IMG_001.jpg"), natural_sort_key("img_001.jpg"));
    }

    // R2-01: sort_filelist applies natural sort then cover/credit rotation.
    #[test]
    fn sort_filelist_natural_order() {
        let mut files: Vec<String> = vec![
            "page1.jpg".into(),
            "page10.jpg".into(),
            "page2.jpg".into(),
        ];
        sort_filelist(&mut files);
        assert_eq!(files, vec!["page1.jpg", "page2.jpg", "page10.jpg"]);
    }

    #[test]
    fn sort_filelist_cover_moved_to_front() {
        let mut files: Vec<String> = vec![
            "page01.jpg".into(),
            "cover.jpg".into(),
            "page02.jpg".into(),
        ];
        sort_filelist(&mut files);
        assert_eq!(files[0], "cover.jpg");
    }

    #[test]
    fn sort_filelist_credit_moved_to_end() {
        let mut files: Vec<String> = vec![
            "credit.jpg".into(),
            "page01.jpg".into(),
            "page02.jpg".into(),
        ];
        sort_filelist(&mut files);
        assert_eq!(files.last().unwrap(), "credit.jpg");
    }

    #[test]
    fn sort_filelist_back_cover_not_promoted() {
        // "backcover.jpg" contains "cover" but the "back" exception prevents
        // promotion. When a genuine "cover.jpg" is present, it goes first and
        // "backcover.jpg" stays in the "others" bucket behind it.
        let mut files: Vec<String> = vec![
            "backcover.jpg".into(),
            "cover.jpg".into(),
            "page01.jpg".into(),
        ];
        sort_filelist(&mut files);
        assert_eq!(files[0], "cover.jpg");
        // backcover.jpg is not in the cover bucket — verify it did NOT jump
        // ahead of page01.jpg (which natural-sorts after back*).
        let back_pos = files.iter().position(|f| f == "backcover.jpg").unwrap();
        let page_pos = files.iter().position(|f| f == "page01.jpg").unwrap();
        assert!(back_pos < page_pos, "backcover.jpg stays in others, ordered before page01 by natural sort");
    }

    // R2-02: basename extraction used in thumb must match archive extractor.
    #[test]
    fn basename_sort_key_for_nested_paths() {
        // When extracting basename, sort key must be natural (same as sort_filelist).
        let paths = vec!["subdir2/p1.jpg", "subdir1/p2.jpg"];
        let mut basenames: Vec<String> = paths
            .iter()
            .map(|p| {
                Path::new(p)
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        basenames.sort_by(|a, b| natural_sort_key(a).cmp(&natural_sort_key(b)));
        // p1 < p2 numerically; p1.jpg comes first.
        assert_eq!(basenames, vec!["p1.jpg", "p2.jpg"]);
    }

    #[test]
    fn derive_title_strips_extension() {
        assert_eq!(derive_title("my_manga.cbz"), "my_manga");
        assert_eq!(derive_title("nested/dir/book.zip"), "book");
        assert_eq!(derive_title("noext"), "noext");
    }

    #[test]
    fn is_image_filename_matches_supported_formats() {
        assert!(is_image_filename("page01.jpg"));
        assert!(is_image_filename("page01.JPEG"));
        assert!(is_image_filename("cover.PNG"));
        assert!(is_image_filename("anim.gif"));
        assert!(is_image_filename("modern.webp"));
        assert!(!is_image_filename("readme.txt"));
        assert!(!is_image_filename("archive.zip"));
        assert!(!is_image_filename("noext"));
    }

    #[test]
    fn build_page_urls_encodes_spaces() {
        let urls = build_page_urls(
            "d1858d5dc36925aa66be072a97817650d39de166",
            &["page 01.jpg".to_string()],
        );
        assert!(urls[0].contains("%20"));
        assert!(urls[0].starts_with(
            "/api/archives/d1858d5dc36925aa66be072a97817650d39de166/page?path="
        ));
    }
}
