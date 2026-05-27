//! Stamps theme handlers.

use axum::{Json, extract::{Path, Query, State}};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::{ApiError, TagErr};
use crate::openapi::responses::op_success;
use crate::service;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct AddStampQuery {
    pub content:  Option<String>,
    pub position: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateStampQuery {
    pub content:  Option<String>,
    pub position: Option<String>,
}
pub async fn stamped_pages(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let pages = service::stamps::stamped_pages(&state.db, &id)
        .await
        .tag_err("stampedPages")?;

    Ok(Json(json!({ "result": pages })))
}
pub async fn stamps_by_page(
    State(state): State<AppState>,
    Path((id, index)): Path<(String, i32)>,
) -> Result<Json<Value>, ApiError> {
    let stamps = service::stamps::stamps_by_page(&state.db, &id, index)
        .await
        .tag_err("stampsByPage")?;

    Ok(Json(json!({ "result": stamps })))
}
pub async fn add_stamp(
    State(state): State<AppState>,
    Path((id, index)): Path<(String, i32)>,
    Query(query): Query<AddStampQuery>,
) -> Result<Json<Value>, ApiError> {
    let content  = query.content.as_deref().unwrap_or("");
    let position = query.position.as_deref().unwrap_or("");

    let stamp_id = service::stamps::add_stamp(&state.db, &id, index, content, position)
        .await
        .tag_err("addStamp")?;

    Ok(Json(json!({
        "operation": "add_stamp",
        "stamp_id": stamp_id,
        "success": 1,
    })))
}
pub async fn get_stamp(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let stamp = service::stamps::get_stamp(&state.db, &id)
        .await
        .tag_err("getStamp")?;

    Ok(Json(json!(stamp)))
}
pub async fn update_stamp(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<UpdateStampQuery>,
) -> Result<Json<Value>, ApiError> {
    service::stamps::update_stamp(
        &state.db,
        &id,
        query.position.as_deref(),
        query.content.as_deref(),
    )
    .await
    .tag_err("updateStamp")?;

    Ok(op_success("updateStamp"))
}
pub async fn delete_stamp(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    service::stamps::delete_stamp(&state.db, &id)
        .await
        .tag_err("deleteStamp")?;

    Ok(op_success("deleteStamp"))
}
