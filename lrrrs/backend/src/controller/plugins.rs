//! Plugin theme handlers. LRRRS has no plugin system; all endpoints return no-op responses.
//!
//! `listPlugins` returns an empty array so clients enumerating plugins observe
//! "none installed" rather than a 501 error. `usePluginSync` and `usePluginAsync`
//! are permanent 501: plugin execution is not supported and will never be added.

use axum::{Json, extract::{Path, State}};
use serde_json::Value;

use crate::error::ApiError;
use crate::state::AppState;

pub async fn list_plugins(
    State(_state): State<AppState>,
    Path(_type): Path<String>,
) -> Result<Json<Vec<Value>>, ApiError> {
    Ok(Json(Vec::new()))
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
