//! Tankoubon theme handlers.

use axum::{Json, extract::{Path, State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn add_to_tankoubon(
    State(_state): State<AppState>,
    Path((_id, _archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("addToTankoubon"))
}

pub async fn create_tankoubon(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("createTankoubon"))
}

pub async fn delete_tankoubon(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("deleteTankoubon"))
}

pub async fn get_tankoubon(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getTankoubon"))
}

pub async fn get_tankoubon_list(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getTankoubonList"))
}

pub async fn get_tankoubon_thumbnail(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getTankoubonThumbnail"))
}

pub async fn remove_from_tankoubon(
    State(_state): State<AppState>,
    Path((_id, _archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("removeFromTankoubon"))
}

pub async fn update_tankoubon(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateTankoubon"))
}

pub async fn update_tankoubon_progress(
    State(_state): State<AppState>,
    Path((_id, _page)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateTankoubonProgress"))
}

pub async fn update_tankoubon_thumbnail(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateTankoubonThumbnail"))
}
