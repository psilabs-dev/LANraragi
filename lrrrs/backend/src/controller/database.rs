//! Database theme handlers.

use axum::{Json, extract::{Path, State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn clean_database(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("cleanDatabase"))
}

pub async fn clear_new_all(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("clearNewAll"))
}

pub async fn download_backup(
    State(_state): State<AppState>,
    Path(_jobid): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("downloadBackup"))
}

pub async fn drop_database(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("dropDatabase"))
}

pub async fn get_backup_json(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getBackupJson"))
}

pub async fn get_statistics(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getStatistics"))
}

pub async fn queue_backup_job(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("queueBackupJob"))
}

pub async fn queue_restore_job(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("queueRestoreJob"))
}
