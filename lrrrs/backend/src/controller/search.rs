//! Search theme handlers.

use axum::{Json, extract::{State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn discard_search_cache(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("discardSearchCache"))
}

pub async fn search_archives(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("searchArchives"))
}

pub async fn search_random_archives(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("searchRandomArchives"))
}
