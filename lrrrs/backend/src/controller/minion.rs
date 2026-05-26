//! Minion (job queue) theme handlers.

use axum::{Json, extract::{Path, Query, State}};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::{ApiError, TagErr};
use crate::service;
use crate::state::AppState;

// port of LANraragi::Controller::Api::Minion::minion_job_status
// commit hash: f7249980
pub async fn minion_job_status(
    State(state): State<AppState>,
    Path(jobid): Path<i64>,
) -> Result<Json<Value>, ApiError> {
    let status = service::minion::fetch_status(&state.db, jobid)
        .await
        .map_err(|e| ApiError::internal("minionJobStatus", e.to_string()))?;
    status
        .map(Json)
        .ok_or_else(|| ApiError::not_found("minionJobStatus", "No job with this ID."))
}

// port of LANraragi::Controller::Api::Minion::minion_job_detail
// commit hash: f7249980
pub async fn minion_job_detail(
    State(state): State<AppState>,
    Path(jobid): Path<i64>,
) -> Result<Json<Value>, ApiError> {
    let detail = service::minion::fetch_detail(&state.db, jobid)
        .await
        .map_err(|e| ApiError::internal("minionJobDetail", e.to_string()))?;
    detail
        .map(Json)
        .ok_or_else(|| ApiError::not_found("minionJobDetail", "No job with this ID."))
}

#[derive(Deserialize)]
pub struct QueueParams {
    args: String,
    #[serde(default)]
    priority: i32,
}

// port of LANraragi::Controller::Api::Minion::queue_minion_job
// commit hash: f7249980
pub async fn queue_minion_job(
    State(state): State<AppState>,
    Path(jobname): Path<String>,
    Query(params): Query<QueueParams>,
) -> Result<Json<Value>, ApiError> {
    let id = service::minion::enqueue(
        &state.db,
        &state.minion,
        &jobname,
        &params.args,
        params.priority,
    )
    .await
    .tag_err("queueMinionJob")?;
    Ok(Json(json!({
        "operation": "queue_minion_job",
        "success": 1,
        "job": id,
    })))
}
