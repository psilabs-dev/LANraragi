//! Search theme handlers.

use axum::{Json, extract::{Query, State}};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::ApiError;
use crate::openapi::responses::op_success;
use crate::service;
use crate::service::search::SearchInput;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct SearchQuery {
    pub filter: Option<String>,
    pub category: Option<String>,
    pub start: Option<i64>,
    pub sortby: Option<String>,
    pub order: Option<String>,
    pub newonly: Option<String>,
    pub untaggedonly: Option<String>,
    pub groupby_tanks: Option<String>,
    pub hidecompleted: Option<String>,
}

#[derive(Deserialize)]
pub struct RandomSearchQuery {
    pub filter: Option<String>,
    pub category: Option<String>,
    pub count: Option<usize>,
    pub newonly: Option<String>,
    pub untaggedonly: Option<String>,
    pub groupby_tanks: Option<String>,
    pub hidecompleted: Option<String>,
}
pub async fn search_archives(
    State(state): State<AppState>,
    Query(q): Query<SearchQuery>,
) -> Result<Json<Value>, ApiError> {
    let sort_desc = q.order.as_deref() == Some("desc");
    let newonly = q.newonly.as_deref() == Some("true");
    let untaggedonly = q.untaggedonly.as_deref() == Some("true");
    let grouptanks = q.groupby_tanks.as_deref() == Some("true");
    let hidecompleted = q.hidecompleted.as_deref() == Some("true");
    let start = q.start.unwrap_or(0);

    let pagesize = i64::from(state.lrr_config.pagesize);

    let input = SearchInput {
        filter: q.filter.as_deref(),
        category_id: q.category.as_deref(),
        start,
        sortby: q.sortby.as_deref(),
        sort_desc,
        newonly,
        untaggedonly,
        grouptanks,
        hidecompleted,
        pagesize,
    };

    let result = service::search::search_archive_index(&state.db, &input)
        .await
        .map_err(|e| ApiError::internal("searchArchives", e.to_string()))?;

    Ok(Json(json!({
        "recordsTotal": result.records_total,
        "recordsFiltered": result.records_filtered,
        "data": result.data,
    })))
}
pub async fn search_random_archives(
    State(state): State<AppState>,
    Query(q): Query<RandomSearchQuery>,
) -> Result<Json<Value>, ApiError> {
    let newonly = q.newonly.as_deref() == Some("true");
    let untaggedonly = q.untaggedonly.as_deref() == Some("true");
    let grouptanks = q.groupby_tanks.as_deref() == Some("true");
    let hidecompleted = q.hidecompleted.as_deref() == Some("true");
    let count = q.count.unwrap_or(5);

    let data = service::search::search_random_archives(
        &state.db,
        q.filter.as_deref(),
        q.category.as_deref(),
        newonly,
        untaggedonly,
        grouptanks,
        hidecompleted,
        count,
    )
    .await
    .map_err(|e| ApiError::internal("searchRandomArchives", e.to_string()))?;

    let records_total = data.len() as i64;

    Ok(Json(json!({
        "data": data,
        "recordsTotal": records_total,
    })))
}

// Returns `{"operation":"clear_cache",...}`; Perl `clear_cache` route name per
// `x-mojo-to: api-search#clear_cache` and `render_api_response($self, "clear_cache")`.
// Postgres has no app-level search cache; this endpoint is a no-op per dev-sql parity.
pub async fn discard_search_cache(
    State(_state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    Ok(op_success("clear_cache"))
}
