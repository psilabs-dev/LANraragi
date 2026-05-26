//! Archive theme handlers.

use std::path::PathBuf;

use axum::{
    Json,
    extract::{Multipart, Path, State},
};
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use tokio::io::AsyncWriteExt;
use tracing::warn;

use crate::error::{ApiError, TagErr};
use crate::openapi::types::ArchiveMetadataJson;
use crate::service;
use crate::service::archive::UploadInput;
use crate::state::AppState;

pub async fn add_archive_toc(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("addArchiveToc"))
}

pub async fn clear_new_archive_flag(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("clearNewArchiveFlag"))
}

pub async fn delete_archive(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("deleteArchive"))
}

pub async fn delete_archive_toc(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("deleteArchiveToc"))
}

pub async fn download_archive(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("downloadArchive"))
}

// port of LANraragi::Controller::Api::Archive::serve_archivelist
// commit hash: cabaef92
pub async fn get_all_archives(
    State(state): State<AppState>,
) -> Result<Json<Vec<ArchiveMetadataJson>>, ApiError> {
    let archives = service::archive::list_all(&state.db)
        .await
        .map_err(|e| ApiError::internal("getAllArchives", e.to_string()))?;
    Ok(Json(archives))
}

pub async fn get_archive(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getArchive"))
}

pub async fn get_archive_categories(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getArchiveCategories"))
}

pub async fn get_archive_metadata(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getArchiveMetadata"))
}

pub async fn get_archive_tankoubons(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getArchiveTankoubons"))
}

pub async fn get_archive_thumbnail(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getArchiveThumbnail"))
}

pub async fn get_files(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getFiles"))
}

pub async fn get_page(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getPage"))
}

pub async fn get_untagged_archives(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getUntaggedArchives"))
}

pub async fn queue_archive_page_thumbnail_extraction(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("queueArchivePageThumbnailExtraction"))
}

pub async fn set_new_archive_flag(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("setNewArchiveFlag"))
}

pub async fn update_archive_metadata(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateArchiveMetadata"))
}

pub async fn update_archive_progress(
    State(_state): State<AppState>,
    Path((_id, _page)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateArchiveProgress"))
}

pub async fn update_archive_thumbnail(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateArchiveThumbnail"))
}

/// RAII guard that removes a temp file on drop unless explicitly disarmed.
/// The cleanup is dispatched to a tokio task so that `Drop` runs synchronously.
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

// port of LANraragi::Controller::Api::Archive::create_archive
// commit hash: cabaef92
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
                    arcsize = arcsize.saturating_add(i64::try_from(chunk.len()).unwrap_or(i64::MAX));
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

    // category_id and tags are accepted on the wire but their persistence
    // lands in a later slice alongside category/tag service helpers.
    let _ = (category_id, tags);

    let input = UploadInput {
        temp_path: temp_path.clone(),
        arcid,
        user_filename,
        file_checksum,
        title,
        summary,
        arcsize,
    };

    let arcid = service::archive::upload(&state.db, &state.rayon, &state.config.content_dir, input)
        .await
        .tag_err("uploadArchive")?;

    temp_guard.disarm();

    Ok(Json(json!({
        "operation": "upload",
        "success": 1,
        "id": arcid,
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

fn temp_suffix() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:032x}")
}

