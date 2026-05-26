//! Plugin theme handlers. LRRRS has no plugin system; all routes return 501.

use axum::{Json, extract::{Path, State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn list_plugins(
    State(_state): State<AppState>,
    Path(_type): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("listPlugins"))
}

pub async fn use_plugin_async(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("usePluginAsync"))
}

pub async fn use_plugin_sync(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("usePluginSync"))
}
