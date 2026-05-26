//! Category theme handlers.

use axum::{Json, extract::{Path, State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn add_to_category(
    State(_state): State<AppState>,
    Path((_id, _archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("addToCategory"))
}

pub async fn create_category(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("createCategory"))
}

pub async fn delete_category(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("deleteCategory"))
}

pub async fn get_bookmark_link(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getBookmarkLink"))
}

pub async fn get_category(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getCategory"))
}

pub async fn get_category_list(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getCategoryList"))
}

pub async fn remove_bookmark_link(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("removeBookmarkLink"))
}

pub async fn remove_from_category(
    State(_state): State<AppState>,
    Path((_id, _archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("removeFromCategory"))
}

pub async fn update_bookmark_link(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateBookmarkLink"))
}

pub async fn update_category(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("updateCategory"))
}
