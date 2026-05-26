//! Miscellaneous API handlers.

use axum::{Json, extract::State};
use serde_json::Value;

use crate::error::ApiError;
use crate::openapi::types::ServerInfo;
use crate::service;
use crate::state::AppState;

pub async fn root(State(app_state): State<AppState>) -> String {
    format!(
        "lrrrs backend scaffold listening on {}",
        app_state.config.bind_addr
    )
}

pub async fn health() -> &'static str {
    "ok"
}

pub async fn clean_tempfolder(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("cleanTempfolder"))
}

pub async fn download_url(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("downloadUrl"))
}

// port of LANraragi::Controller::Api::Other::serve_serverinfo
// commit hash: 61de905b
pub async fn get_server_info(
    State(state): State<AppState>,
) -> Result<Json<ServerInfo>, ApiError> {
    let info = service::misc::build_server_info(&state.db)
        .await
        .map_err(|e| ApiError::internal("getServerInfo", e.to_string()))?;
    Ok(Json(info))
}

pub async fn regen_thumbnails(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Err(ApiError::not_implemented("regenThumbnails"))
}
