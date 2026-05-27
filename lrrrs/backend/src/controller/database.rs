//! Database theme handlers.

use axum::{
    Json,
    extract::{Multipart, Path, Query, State},
    http::{HeaderMap, HeaderValue, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::{ApiError, TagErr};
use crate::openapi::responses::op_success;
use crate::service;
use crate::state::AppState;
pub async fn clean_database(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let (deleted, unlinked) = service::database::clean_database(&state.db)
        .await
        .tag_err("cleanDatabase")?;
    Ok(Json(json!({
        "operation": "clean_database",
        "success": 1,
        "deleted": deleted,
        "unlinked": unlinked,
    })))
}
pub async fn clear_new_all(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    service::database::clear_isnew_all(&state.db)
        .await
        .tag_err("clearNewAll")?;
    Ok(op_success("clear_new_all"))
}
pub async fn drop_database(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    service::database::drop_database(
        &state.db,
        &state.api_key_hash,
        &state.verify_cache,
    )
    .await
    .tag_err("dropDatabase")?;
    Ok(op_success("drop_database"))
}
pub async fn get_backup_json(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let backup = service::backup::build_backup_json(&state.db)
        .await
        .tag_err("getBackupJson")?;
    Ok(Json(backup))
}

#[derive(Deserialize)]
pub struct StatsParams {
    #[serde(default = "default_minweight")]
    minweight: i64,
    /// When "true", exclude namespaces listed in server config from results.
    #[serde(default)]
    hide_excluded_namespaces: String,
}

fn default_minweight() -> i64 {
    1
}
pub async fn get_statistics(
    State(state): State<AppState>,
    Query(params): Query<StatsParams>,
) -> Result<Json<Value>, ApiError> {
    let excluded = if params.hide_excluded_namespaces == "true" {
        // Read excluded_namespaces from DB on each request so that changes
        // made via the Postgres admin interface are visible without a restart.
        let raw = crate::db::config::load_excluded_namespaces(&state.db)
            .await
            .map_err(|e| ApiError::internal("getStatistics", e.to_string()))?;
        raw.split(',')
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .collect::<Vec<String>>()
    } else {
        Vec::new()
    };

    let stats = service::database::get_statistics(&state.db, params.minweight, &excluded)
        .await
        .tag_err("getStatistics")?;

    Ok(Json(Value::Array(stats)))
}
pub async fn queue_backup_job(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let id = service::minion::enqueue(
        &state.db,
        &state.minion,
        "backup_json",
        "[]",
        0,
    )
    .await
    .tag_err("queueBackupJob")?;

    Ok(Json(json!({
        "operation": "queue_backup",
        "success": 1,
        "job": id,
    })))
}
pub async fn queue_restore_job(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> Result<Json<Value>, ApiError> {
    let mut json_data: Option<String> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::bad_request("queueRestoreJob", e.to_string()))?
    {
        if field.name() == Some("file") {
            let bytes = field
                .bytes()
                .await
                .map_err(|e| ApiError::bad_request("queueRestoreJob", e.to_string()))?;
            let text = String::from_utf8(bytes.to_vec())
                .map_err(|_| ApiError::bad_request("queueRestoreJob", "File must be UTF-8 JSON"))?;
            json_data = Some(text);
            break;
        }
    }

    let json_str = json_data.ok_or_else(|| {
        ApiError::bad_request("queueRestoreJob", "No file provided")
    })?;

    // Validate that it is parseable JSON before enqueueing.
    serde_json::from_str::<Value>(&json_str)
        .map_err(|_| ApiError::bad_request("queueRestoreJob", "File must be JSON"))?;

    // Encode the JSON string as the sole task argument.
    let args_json = serde_json::to_string(&json!([json_str]))
        .map_err(|e| ApiError::internal("queueRestoreJob", e.to_string()))?;

    let id = service::minion::enqueue(
        &state.db,
        &state.minion,
        "restore_backup",
        &args_json,
        0,
    )
    .await
    .tag_err("queueRestoreJob")?;

    Ok(Json(json!({
        "operation": "queue_restore",
        "success": 1,
        "job": id,
    })))
}

#[derive(Deserialize)]
pub struct DownloadBackupParams {
    format: Option<String>,
}
pub async fn download_backup(
    State(state): State<AppState>,
    Path(jobid): Path<i64>,
    Query(params): Query<DownloadBackupParams>,
) -> Result<Response, ApiError> {
    let path_str = service::database::get_backup_path(&state.db, jobid)
        .await
        .tag_err("downloadBackup")?
        .ok_or_else(|| ApiError::not_found("downloadBackup", "Job not found"))?;

    let bytes = tokio::fs::read(&path_str).await.map_err(|_| {
        ApiError::bad_request("downloadBackup", "Backup file not found on disk")
    })?;

    if params.format.as_deref() == Some("json") {
        // Return parsed JSON body.
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|e| ApiError::internal("downloadBackup", e.to_string()))?;
        return Ok(Json(value).into_response());
    }

    // Serve as a file download.
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_static("attachment; filename=\"backup.json\""),
    );

    Ok((headers, bytes).into_response())
}
