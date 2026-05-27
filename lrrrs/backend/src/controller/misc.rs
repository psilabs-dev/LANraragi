//! Miscellaneous API handlers.

use axum::{Json, extract::{Multipart, Query, State}};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::{ApiError, TagErr};
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
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    service::misc::clean_tempfolder(&state.config.temp_dir)
        .await
        .tag_err("cleanTempfolder")?;

    Ok(Json(json!({
        "operation": "cleantemp",
        "success": 1,
        "error": null,
        "newsize": 0,
    })))
}

#[derive(Deserialize)]
pub struct DownloadUrlParams {
    url: Option<String>,
    catid: Option<String>,
}
//
// The openapi.yaml spec supports both `in: query` and `requestBody.multipart/form-data`
// shapes for this endpoint. If the request body is multipart/form-data, fields are
// parsed from the body; otherwise query params are used as fallback.
pub async fn download_url(
    State(state): State<AppState>,
    Query(query): Query<DownloadUrlParams>,
    multipart: Option<Multipart>,
) -> Result<Json<Value>, ApiError> {
    let (url, catid) = if let Some(mut mp) = multipart {
        let mut url: Option<String> = None;
        let mut catid: Option<String> = None;
        while let Some(field) = mp
            .next_field()
            .await
            .map_err(|e| ApiError::bad_request("downloadUrl", e.to_string()))?
        {
            match field.name() {
                Some("url") => {
                    url = Some(
                        field
                            .text()
                            .await
                            .map_err(|e| ApiError::bad_request("downloadUrl", e.to_string()))?,
                    );
                }
                Some("catid") => {
                    catid = Some(
                        field
                            .text()
                            .await
                            .map_err(|e| ApiError::bad_request("downloadUrl", e.to_string()))?,
                    );
                }
                _ => {}
            }
        }
        (url, catid)
    } else {
        (query.url, query.catid)
    };

    let url = url.as_deref().unwrap_or("").trim().to_string();
    if url.is_empty() {
        return Err(ApiError::bad_request("downloadUrl", "No URL specified."));
    }

    let job = service::misc::enqueue_download_url(
        &state.db,
        &state.minion,
        &url,
        catid.as_deref(),
    )
    .await
    .tag_err("downloadUrl")?;

    Ok(Json(json!({
        "operation": "download_url",
        "url": url,
        "category": catid,
        "success": 1,
        "job": job,
    })))
}

#[derive(Deserialize)]
pub struct RegenThumbsParams {
    #[serde(default)]
    force: bool,
}
pub async fn regen_thumbnails(
    State(state): State<AppState>,
    Query(params): Query<RegenThumbsParams>,
) -> Result<Json<Value>, ApiError> {
    let job = service::misc::enqueue_regen_thumbnails(&state.db, &state.minion, &state.config.thumb_dir, params.force)
        .await
        .tag_err("regenThumbnails")?;

    Ok(Json(json!({
        "operation": "regen_thumbnails",
        "success": 1,
        "job": job,
    })))
}
pub async fn get_server_info(
    State(state): State<AppState>,
) -> Result<Json<ServerInfo>, ApiError> {
    // Read excluded_namespaces from DB on each request so that changes
    // made via the Postgres admin interface are visible without a restart.
    let excluded_namespaces_raw = crate::db::config::load_excluded_namespaces(&state.db)
        .await
        .map_err(|e| ApiError::internal("getServerInfo", e.to_string()))?;
    let info = service::misc::build_server_info(&state.db, &state.lrr_config, &excluded_namespaces_raw)
        .await
        .map_err(|e| ApiError::internal("getServerInfo", e.to_string()))?;
    Ok(Json(info))
}
