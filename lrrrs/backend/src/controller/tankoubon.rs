//! Tankoubon theme handlers.

use axum::{
    Json,
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::{ApiError, TagErr};
use crate::openapi::responses::op_success;
use crate::service;
use crate::service::tankoubons::UpdateInput;
use crate::state::AppState;
use super::FormOrQuery;

#[derive(Deserialize)]
pub struct TankoubonListParams {
    page: Option<i64>,
}
pub async fn get_tankoubon_list(
    State(state): State<AppState>,
    Query(params): Query<TankoubonListParams>,
) -> Result<Json<Value>, ApiError> {
    let pagesize = i64::from(state.lrr_config.pagesize);
    let (total, filtered, items) =
        service::tankoubons::list(&state.db, params.page, pagesize)
            .await
            .tag_err("getTankoubonList")?;

    let result: Vec<Value> = items
        .iter()
        .map(service::tankoubons::list_item_to_json)
        .collect();

    Ok(Json(json!({
        "result": result,
        "total": total,
        "filtered": filtered,
    })))
}

#[derive(Deserialize)]
pub struct TankoubonGetParams {
    include_full_data: Option<bool>,
    page: Option<i64>,
}
pub async fn get_tankoubon(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<TankoubonGetParams>,
) -> Result<Json<Value>, ApiError> {
    let pagesize = i64::from(state.lrr_config.pagesize);
    let include_full = params.include_full_data.unwrap_or(false);

    let detail = service::tankoubons::get(&state.db, &id, include_full, params.page, pagesize)
        .await
        .tag_err("getTankoubon")?;

    let mut result = json!({
        "id": detail.id,
        "name": detail.name,
        "summary": detail.summary,
        "tags": detail.tags,
        "archives": detail.archives,
    });

    if let Some(full) = detail.full_data {
        result["full_data"] = serde_json::to_value(full).unwrap_or(Value::Array(vec![]));
    }

    Ok(Json(json!({
        "result": result,
        "total": detail.total,
        "filtered": detail.filtered,
    })))
}

/// Form body for tankoubon create requests.
/// aiohttp sends text-only fields as application/x-www-form-urlencoded.
#[derive(Deserialize, Default)]
pub struct CreateTankoubonForm {
    #[serde(default)]
    pub name: String,
    pub tankid: Option<String>,
}
pub async fn create_tankoubon(
    State(state): State<AppState>,
    FormOrQuery(form): FormOrQuery<CreateTankoubonForm>,
) -> Result<Json<Value>, ApiError> {
    if form.name.is_empty() {
        return Err(ApiError::bad_request(
            "createTankoubon",
            "Tankoubon name not specified.",
        ));
    }
    let tankid = form.tankid.filter(|s| !s.is_empty());

    let created_id = service::tankoubons::create(&state.db, &form.name, tankid.as_deref())
        .await
        .tag_err("createTankoubon")?;

    Ok(Json(json!({
        "operation": "create_tankoubon",
        "tankoubon_id": created_id,
        "success": 1,
    })))
}
pub async fn delete_tankoubon(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    service::tankoubons::delete(&state.db, &id)
        .await
        .tag_err("deleteTankoubon")?;
    Ok(op_success("deleteTankoubon"))
}

/// JSON body for `PUT /tankoubons/{id}`.
#[derive(Deserialize)]
pub struct UpdateTankoubonBody {
    archives: Option<Vec<String>>,
    metadata: Option<UpdateTankoubonMeta>,
}

#[derive(Deserialize)]
pub struct UpdateTankoubonMeta {
    name: Option<String>,
    summary: Option<String>,
    tags: Option<String>,
}
pub async fn update_tankoubon(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<UpdateTankoubonBody>,
) -> Result<Json<Value>, ApiError> {
    let meta = body.metadata.as_ref();
    let input = UpdateInput {
        name: meta.and_then(|m| m.name.clone()),
        summary: meta.and_then(|m| m.summary.clone()),
        tags: meta.and_then(|m| m.tags.clone()),
        archives: body.archives.clone(),
    };

    let updated_name = service::tankoubons::update(&state.db, &id, input)
        .await
        .tag_err("updateTankoubon")?;

    // Re-queue cover thumbnail only when the archive list was present in the request body.
    if body.archives.is_some() {
        let _ = service::tankoubons::enqueue_thumbnail_job(&state.db, &id)
            .await
            .map_err(|e| ApiError::internal("updateTankoubon", e.to_string()))?;
    }

    Ok(Json(json!({
        "operation": "update_tankoubon",
        "success": 1,
        "successMessage": format!("Updated tankoubon \"{}\"!", updated_name),
    })))
}
pub async fn add_to_tankoubon(
    State(state): State<AppState>,
    Path((id, archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    service::tankoubons::add_archive(&state.db, &id, &archive)
        .await
        .tag_err("addToTankoubon")?;
    Ok(op_success("addToTankoubon"))
}
pub async fn remove_from_tankoubon(
    State(state): State<AppState>,
    Path((id, archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    service::tankoubons::remove_archive(&state.db, &id, &archive)
        .await
        .tag_err("removeFromTankoubon")?;

    // Re-queue cover thumbnail after archive removal.
    let _ = service::tankoubons::enqueue_thumbnail_job(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("removeFromTankoubon", e.to_string()))?;

    Ok(op_success("removeFromTankoubon"))
}
pub async fn update_tankoubon_progress(
    State(state): State<AppState>,
    Path((id, page)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    // The route path segment is a string; coerce to i32.
    let page_num: i32 = page
        .parse()
        .map_err(|_| ApiError::bad_request("updateTankoubonProgress", "Invalid progress value."))?;

    // Respect localprogress flag: if server-side progress is disabled, reject.
    if state.lrr_config.localprogress && !state.lrr_config.authprogress {
        return Err(ApiError::bad_request(
            "updateTankoubonProgress",
            "Server-side Progress Tracking is disabled on this instance.",
        ));
    }

    let result = service::tankoubons::update_progress(&state.db, &id, page_num)
        .await
        .tag_err("updateTankoubonProgress")?;

    Ok(Json(json!({
        "operation": "update_tank_progress",
        "id": id,
        "page": result.page,
        "lastreadtime": result.lastreadtime,
        "success": 1,
    })))
}

#[derive(Deserialize)]
pub struct ThumbnailParams {
    no_fallback: Option<String>,
    page: Option<i64>,
}

// Returns `{"operation":"serve_tankoubon_thumbnail",...}`.
pub async fn get_tankoubon_thumbnail(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<ThumbnailParams>,
) -> Result<Response, ApiError> {
    let no_fallback = params.no_fallback.as_deref() == Some("true");

    // Verify the tank exists (spec declares 400 for missing tank).
    let exists = service::tankoubons::tank_exists(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("getTankoubonThumbnail", e.to_string()))?;
    if !exists {
        return Err(ApiError::bad_request(
            "getTankoubonThumbnail",
            "The given tankoubon does not exist.",
        ));
    }

    use crate::service::archive::ThumbnailResult;

    let result = service::tankoubons::get_thumbnail(&state.db, &state.config.thumb_dir, &id, no_fallback)
        .await
        .map_err(|e| ApiError::internal("getTankoubonThumbnail", e.to_string()))?;

    match result {
        ThumbnailResult::Bytes(bytes) => {
            let mut headers = HeaderMap::new();
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("image/webp"),
            );
            Ok((StatusCode::OK, headers, bytes).into_response())
        }
        ThumbnailResult::Queued(job_id) => Ok((
            StatusCode::ACCEPTED,
            Json(json!({
                "operation": "serve_tankoubon_thumbnail",
                "job": job_id,
                "success": 1,
            })),
        )
            .into_response()),
    }
}
pub async fn update_tankoubon_thumbnail(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<ThumbnailParams>,
) -> Result<Json<Value>, ApiError> {
    let page = params.page.unwrap_or(1);
    if page < 1 {
        return Err(ApiError::bad_request(
            "updateTankoubonThumbnail",
            "Page must be >= 1.",
        ));
    }

    // Verify the tank exists (spec declares 400 for missing tank).
    let exists = service::tankoubons::tank_exists(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("updateTankoubonThumbnail", e.to_string()))?;
    if !exists {
        return Err(ApiError::bad_request(
            "updateTankoubonThumbnail",
            "The given tankoubon does not exist.",
        ));
    }

    // Reject out-of-range pages before enqueuing (mirrors Perl translate_global_page).
    let total_pagecount = service::tankoubons::total_pagecount(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("updateTankoubonThumbnail", e.to_string()))?;
    if page > total_pagecount {
        return Err(ApiError::bad_request(
            "updateTankoubonThumbnail",
            &format!("Page {page} is out of range for this tankoubon."),
        ));
    }

    let job_id = service::tankoubons::enqueue_thumbnail_job_for_page(&state.db, &id, page)
        .await
        .map_err(|e| ApiError::internal("updateTankoubonThumbnail", e.to_string()))?;

    Ok(Json(json!({
        "operation": "update_tankoubon_thumbnail",
        "success": 1,
        "job": job_id,
    })))
}
