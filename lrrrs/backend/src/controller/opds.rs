//! OPDS catalog handlers.

use axum::{Json, extract::{Path, State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn get_opds_catalog(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getOpdsCatalog"))
}

pub async fn get_opds_item(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getOpdsItem"))
}

pub async fn get_opds_page(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("getOpdsPage"))
}
