//! Archive theme handlers.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use axum::{
    Json,
    body::Body,
    extract::{Multipart, Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use tokio::io::AsyncWriteExt;
use tracing::warn;

use crate::error::{ApiError, TagErr};
use crate::openapi::responses::op_success;
use crate::openapi::types::ArchiveMetadataJson;
use crate::service;
use crate::service::archive::{ThumbnailResult, UploadInput};
use crate::service::category::CategoryError;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct ThumbnailQuery {
    pub page: Option<u32>,
    pub no_fallback: Option<String>,
}

#[derive(Deserialize)]
pub struct TocQuery {
    pub page: i32,
    pub title: Option<String>,
}

#[derive(Deserialize)]
pub struct MetadataQuery {
    pub title: Option<String>,
    pub tags: Option<String>,
    pub summary: Option<String>,
}

#[derive(Deserialize)]
pub struct FilesQuery {
    pub force: Option<bool>,
}

#[derive(Deserialize)]
pub struct PageQuery {
    pub path: String,
}

#[derive(Deserialize)]
pub struct PageThumbnailQuery {
    pub force: Option<bool>,
}

#[derive(Deserialize)]
pub struct UpdateThumbnailQuery {
    pub page: Option<u32>,
}

// Rejects ids shorter than 40 chars or with non-hex characters.
fn validate_arcid(op: &'static str, id: &str) -> Result<(), ApiError> {
    if id.len() < 40 {
        return Err(ApiError::bad_request(
            op,
            &format!("String is too short: {}/40.", id.len()),
        ));
    }
    if id.len() > 40 {
        return Err(ApiError::bad_request(
            op,
            &format!("String is too long: {}/40.", id.len()),
        ));
    }
    if !id.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(ApiError::bad_request(
            op,
            "Archive ID must be a lowercase hex SHA-1 hash.",
        ));
    }
    Ok(())
}
pub async fn get_all_archives(
    State(state): State<AppState>,
) -> Result<Json<Vec<ArchiveMetadataJson>>, ApiError> {
    let archives = service::archive::list_all(&state.db)
        .await
        .map_err(|e| ApiError::internal("getAllArchives", e.to_string()))?;
    Ok(Json(archives))
}
pub async fn get_untagged_archives(
    State(state): State<AppState>,
) -> Result<Json<Vec<String>>, ApiError> {
    let ids = service::archive::list_untagged(&state.db)
        .await
        .map_err(|e| ApiError::internal("getUntaggedArchives", e.to_string()))?;
    Ok(Json(ids))
}
pub async fn get_archive(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<ArchiveMetadataJson>, ApiError> {
    validate_arcid("getArchive", &id)?;
    let dto = service::archive::get_metadata(&state.db, &id)
        .await
        .tag_err("getArchive")?;
    Ok(Json(dto))
}
pub async fn get_archive_metadata(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<ArchiveMetadataJson>, ApiError> {
    validate_arcid("getArchiveMetadata", &id)?;
    let dto = service::archive::get_metadata(&state.db, &id)
        .await
        .tag_err("getArchiveMetadata")?;
    Ok(Json(dto))
}

// Returns `{"operation":"find_arc_categories",...}` constrained by the spec response enum.
pub async fn get_archive_categories(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let categories = service::archive::get_categories(&state.db, &id)
        .await
        .tag_err("getArchiveCategories")?;
    Ok(Json(json!({
        "operation": "find_arc_categories",
        "success": 1,
        "categories": categories,
    })))
}

// Returns `{"operation":"find_arc_tankoubons",...}` constrained by the spec response enum.
pub async fn get_archive_tankoubons(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let tankoubons = service::archive::get_tankoubons(&state.db, &id)
        .await
        .tag_err("getArchiveTankoubons")?;
    Ok(Json(json!({
        "operation": "find_arc_tankoubons",
        "success": 1,
        "tankoubons": tankoubons,
    })))
}

// The 202 response emits `"operation":"serve_thumbnail"` (not the camelCase operationId).
pub async fn get_archive_thumbnail(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<ThumbnailQuery>,
) -> Result<Response, ApiError> {
    let no_fallback = q
        .no_fallback
        .as_deref()
        .map(|s| s == "true")
        .unwrap_or(false);

    let result = service::archive::get_thumbnail(
        &state.db,
        &state.config.thumb_dir,
        &id,
        q.page,
        no_fallback,
    )
    .await
    .tag_err("getArchiveThumbnail")?;

    match result {
        ThumbnailResult::Bytes(bytes) => {
            let mut headers = HeaderMap::new();
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("image/webp"),
            );
            Ok((StatusCode::OK, headers, bytes).into_response())
        }
        ThumbnailResult::Queued(job_id) => Ok((
            StatusCode::ACCEPTED,
            Json(json!({
                "operation": "serve_thumbnail",
                "success": 1,
                "job": job_id,
            })),
        )
            .into_response()),
    }
}
pub async fn get_files(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<FilesQuery>,
) -> Result<Json<Value>, ApiError> {
    let force = q.force.unwrap_or(false);
    let result = service::archive::get_files(
        &state.db,
        &state.rayon,
        &state.config.temp_dir,
        &id,
        force,
    )
    .await
    .tag_err("getFiles")?;

    Ok(Json(json!({
        "pages": result.pages,
    })))
}
pub async fn get_page(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<PageQuery>,
) -> Result<Response, ApiError> {
    // URL-decode the path parameter before looking up the file.
    let decoded = percent_encoding::percent_decode_str(&q.path)
        .decode_utf8_lossy()
        .into_owned();

    let bytes = service::archive::get_page_bytes(&state.config.temp_dir, &id, &decoded)
        .await
        .tag_err("getPage")?;

    let content_type = mime_for_path(&decoded);
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(content_type).unwrap_or(HeaderValue::from_static("image/jpeg")),
    );

    Ok((StatusCode::OK, headers, bytes).into_response())
}

// Returns `{"operation":"add_new",...}`.
pub async fn set_new_archive_flag(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    service::archive::set_isnew(&state.db, &id, true)
        .await
        .tag_err("setNewArchiveFlag")?;
    Ok(op_success("add_new"))
}

// Returns `{"operation":"clear_new","id":id,...}`. The `id` field is spec-mandated so
// `op_success` cannot be used here; envelope is hand-rolled.
pub async fn clear_new_archive_flag(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    service::archive::set_isnew(&state.db, &id, false)
        .await
        .tag_err("clearNewArchiveFlag")?;
    Ok(Json(json!({
        "operation": "clear_new",
        "id": id,
        "success": 1,
    })))
}
pub async fn update_archive_progress(
    State(state): State<AppState>,
    Path((id, page_str)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let page: i32 = page_str.parse().map_err(|_| {
        ApiError::bad_request("updateArchiveProgress", "page must be an integer")
    })?;

    // localprogress check: reject only when localprogress=true AND authprogress=false.
    // When authprogress is also enabled, updates are permitted (route is already
    // behind the auth gate).
    if state.lrr_config.localprogress && !state.lrr_config.authprogress {
        return Err(ApiError::bad_request(
            "updateArchiveProgress",
            "Server-side Progress Tracking is disabled on this instance.",
        ));
    }

    let (final_page, lastreadtime) = service::archive::update_progress(&state.db, &id, page)
        .await
        .tag_err("updateArchiveProgress")?;

    Ok(Json(json!({
        "operation": "update_progress",
        "id": id,
        "page": final_page,
        "lastreadtime": lastreadtime,
        "success": 1,
    })))
}
pub async fn update_archive_metadata(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<MetadataQuery>,
) -> Result<Json<Value>, ApiError> {
    let msg = service::archive::update_metadata(
        &state.db,
        &id,
        q.title.as_deref(),
        q.tags.as_deref(),
        q.summary.as_deref(),
    )
    .await
    .tag_err("updateArchiveMetadata")?;

    Ok(Json(json!({
        "operation": "update_metadata",
        "success": 1,
        "successMessage": msg,
    })))
}
pub async fn delete_archive(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let filename = service::archive::delete_archive(&state.db, &id)
        .await
        .tag_err("deleteArchive")?;

    let success = if filename.is_empty() { 0 } else { 1 };
    Ok(Json(json!({
        "operation": "delete_archive",
        "id": id,
        "filename": filename,
        "success": success,
    })))
}
pub async fn add_archive_toc(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<TocQuery>,
) -> Result<Json<Value>, ApiError> {
    let title = q
        .title
        .ok_or_else(|| ApiError::bad_request("addArchiveToc", "Missing page and/or title."))?;

    service::archive::add_toc(&state.db, &id, q.page, &title)
        .await
        .tag_err("addArchiveToc")?;

    Ok(Json(json!({
        "operation": "add_toc",
        "success": 1,
        "successMessage": format!("Added ToC entry for page {}.", q.page),
    })))
}
pub async fn delete_archive_toc(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<TocQuery>,
) -> Result<Json<Value>, ApiError> {
    service::archive::delete_toc(&state.db, &id, q.page)
        .await
        .tag_err("deleteArchiveToc")?;

    Ok(Json(json!({
        "operation": "remove_toc",
        "success": 1,
        "successMessage": format!("Removed ToC entry for page {}.", q.page),
    })))
}
pub async fn download_archive(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let path = service::archive::get_file_path(&state.db, &id)
        .await
        .tag_err("downloadArchive")?;

    let filename = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| id.clone());

    let file = tokio::fs::File::open(&path).await.map_err(|e| {
        ApiError::internal("downloadArchive", e.to_string())
    })?;

    // Build RFC 5987-compliant Content-Disposition.
    // ASCII fallback: replace non-ASCII bytes with '_'.
    let ascii_fallback: String = filename.chars().map(|c| if c.is_ascii() { c } else { '_' }).collect();
    // Percent-encode the UTF-8 filename per RFC 5987.
    let encoded = percent_encoding::utf8_percent_encode(
        &filename,
        percent_encoding::NON_ALPHANUMERIC,
    );
    let content_disposition = format!(
        "attachment; filename=\"{ascii_fallback}\"; filename*=UTF-8''{encoded}"
    );
    let stream = tokio_util::io::ReaderStream::new(file);
    let body = Body::from_stream(stream);

    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&content_disposition)
            .unwrap_or(HeaderValue::from_static("attachment")),
    );

    Ok((StatusCode::OK, headers, body).into_response())
}
pub async fn update_archive_thumbnail(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<UpdateThumbnailQuery>,
) -> Result<Json<Value>, ApiError> {
    let page = q.page.unwrap_or(1);
    let new_thumb = service::archive::update_thumbnail(
        &state.db,
        &state.rayon,
        &state.config.thumb_dir,
        &id,
        page,
    )
    .await
    .tag_err("updateArchiveThumbnail")?;

    Ok(Json(json!({
        "operation": "update_thumbnail",
        "success": 1,
        "new_thumbnail": new_thumb,
    })))
}

// Both the 200 and 202 responses emit `"operation":"generate_page_thumbnails"` (not the
// camelCase operationId).
pub async fn queue_archive_page_thumbnail_extraction(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<PageThumbnailQuery>,
) -> Result<Response, ApiError> {
    let force = q.force.unwrap_or(false);
    let job_id = service::archive::queue_page_thumbnails(
        &state.db,
        &state.config.thumb_dir,
        &id,
        force,
    )
    .await
    .tag_err("queueArchivePageThumbnailExtraction")?;

    match job_id {
        None => Ok(Json(json!({
            "operation": "generate_page_thumbnails",
            "success": 1,
            "message": "No job queued, all thumbnails already exist.",
        }))
        .into_response()),
        Some(jid) => Ok((
            StatusCode::ACCEPTED,
            Json(json!({
                "operation": "generate_page_thumbnails",
                "success": 1,
                "job": jid,
            })),
        )
            .into_response()),
    }
}

// RAII guard that removes a temp file on drop unless explicitly disarmed.
struct TempFileGuard {
    path: Option<PathBuf>,
}

impl TempFileGuard {
    fn new(path: PathBuf) -> Self {
        Self { path: Some(path) }
    }

    fn disarm(mut self) {
        self.path.take();
    }
}

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            tokio::spawn(async move {
                if let Err(error) = tokio::fs::remove_file(&path).await
                    && error.kind() != std::io::ErrorKind::NotFound
                {
                    warn!(?path, ?error, "failed to remove upload temp file");
                }
            });
        }
    }
}
pub async fn upload_archive(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> Result<Json<Value>, ApiError> {
    tokio::fs::create_dir_all(&state.config.content_dir)
        .await
        .map_err(|e| ApiError::internal("uploadArchive", e.to_string()))?;

    let temp_path = state
        .config
        .content_dir
        .join(format!(".upload-{}.tmp", temp_suffix()));
    let temp_guard = TempFileGuard::new(temp_path.clone());

    let mut file_handle: Option<tokio::fs::File> = None;
    let mut hasher = Sha1::new();
    let mut arcsize: i64 = 0;
    let mut user_filename: Option<String> = None;
    let mut file_checksum: Option<String> = None;
    let mut title: Option<String> = None;
    let mut summary: Option<String> = None;
    let mut category_id: Option<String> = None;
    let mut tags: Option<String> = None;

    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::bad_request("uploadArchive", e.to_string()))?
    {
        let Some(name) = field.name().map(str::to_string) else {
            continue;
        };
        match name.as_str() {
            "file" => {
                user_filename = field.file_name().map(str::to_string);
                if user_filename.is_none() {
                    return Err(ApiError::bad_request(
                        "uploadArchive",
                        "file part missing filename",
                    ));
                }
                let file = tokio::fs::File::create(&temp_path)
                    .await
                    .map_err(|e| ApiError::internal("uploadArchive", e.to_string()))?;
                file_handle = Some(file);
                while let Some(chunk) = field
                    .chunk()
                    .await
                    .map_err(|e| ApiError::bad_request("uploadArchive", e.to_string()))?
                {
                    hasher.update(&chunk);
                    let chunk_len = i64::try_from(chunk.len())
                        .expect("multipart chunk exceeds i64::MAX bytes");
                    arcsize = arcsize
                        .checked_add(chunk_len)
                        .ok_or_else(|| {
                            ApiError::bad_request(
                                "uploadArchive",
                                "upload size exceeds i64::MAX",
                            )
                        })?;
                    if let Some(handle) = file_handle.as_mut() {
                        handle
                            .write_all(&chunk)
                            .await
                            .map_err(|e| ApiError::internal("uploadArchive", e.to_string()))?;
                    }
                }
            }
            "file_checksum" => file_checksum = Some(read_text_field(field).await?),
            "title" => title = Some(read_text_field(field).await?),
            "summary" => summary = Some(read_text_field(field).await?),
            "category_id" => category_id = Some(read_text_field(field).await?),
            "tags" => tags = Some(read_text_field(field).await?),
            _ => {
                // Unknown fields are ignored, matching LRR's lenient policy.
            }
        }
    }

    let Some(mut file) = file_handle else {
        return Err(ApiError::bad_request(
            "uploadArchive",
            "missing required `file` part",
        ));
    };
    file.flush()
        .await
        .map_err(|e| ApiError::internal("uploadArchive", e.to_string()))?;
    file.sync_all()
        .await
        .map_err(|e| ApiError::internal("uploadArchive", e.to_string()))?;
    drop(file);

    let arcid = hex::encode(hasher.finalize());
    let user_filename = user_filename.expect("file part absence already short-circuited above");

    let input = UploadInput {
        temp_path: temp_path.clone(),
        arcid,
        user_filename,
        file_checksum,
        title,
        summary,
        tags,
        arcsize,
    };

    let arcid =
        service::archive::upload(&state.db, &state.rayon, &state.config.content_dir, input)
            .await
            .tag_err("uploadArchive")?;

    temp_guard.disarm();

    // Apply optional category assignment. A category failure is a soft warning:
    // the archive is already committed. Return 200 + id regardless, with a
    // "warning" field describing the failure (mirrors Perl PgUpload.pm:161-166).
    let mut warning: Option<String> = None;
    if let Some(cid) = category_id.filter(|s| !s.is_empty()) {
        match service::category::add_to_category(&state.db, &cid, &arcid).await {
            Ok(_) => {}
            Err(CategoryError::NotFound(msg)
            | CategoryError::IsDynamic(msg)
            | CategoryError::ArchiveNotFound(msg)) => {
                warning = Some(format!("Couldn't add to Category: {msg}"));
            }
            Err(CategoryError::Db(db)) => {
                return Err(ApiError::internal("uploadArchive", db.to_string()));
            }
        }
    }

    Ok(Json(json!({
        "operation": "upload",
        "success": 1,
        "id": arcid,
        "warning": warning,
    })))
}

async fn read_text_field(
    field: axum::extract::multipart::Field<'_>,
) -> Result<String, ApiError> {
    field
        .text()
        .await
        .map_err(|e| ApiError::bad_request("uploadArchive", e.to_string()))
}

static UPLOAD_COUNTER: AtomicU64 = AtomicU64::new(0);

fn temp_suffix() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch is not supported")
        .as_nanos() as u64;
    let counter = UPLOAD_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{nanos:016x}{counter:016x}")
}

fn mime_for_path(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().map(str::to_ascii_lowercase);
    match ext.as_deref() {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        _ => "image/jpeg",
    }
}
