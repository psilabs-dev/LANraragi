//! Stamps theme handlers.

use axum::{Json, extract::{Path, State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn add_stamp(
    State(_state): State<AppState>,
    Path((_id, _index)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("addStamp"))
}

pub async fn delete_stamp(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("deleteStamp"))
}

pub async fn get_stamp(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getStamp"))
}

pub async fn stamped_pages(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("stampedPages"))
}

pub async fn stamps_by_page(
    State(_state): State<AppState>,
    Path((_id, _index)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("stampsByPage"))
}

pub async fn update_stamp(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateStamp"))
}
