//! Category theme handlers.

use axum::{
    Json,
    extract::{Path, State},
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::error::{ApiError, TagErr};
use crate::openapi::responses::op_success;
use crate::service;
use crate::state::AppState;
use super::FormOrQuery;

/// Form body for category create/update requests.
/// aiohttp sends text-only fields as application/x-www-form-urlencoded.
#[derive(Deserialize, Default)]
pub struct CategoryForm {
    #[serde(default)]
    pub name: String,
    pub search: Option<String>,
    pub pinned: Option<String>,
}
pub async fn get_category_list(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let cats = service::category::list_all(&state.db)
        .await
        .map_err(|e| ApiError::internal("getCategoryList", e.to_string()))?;
    Ok(Json(serde_json::to_value(cats).expect("CategoryDto serializes cleanly")))
}
pub async fn get_category(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let cat = service::category::get(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("getCategory", e.to_string()))?;
    match cat {
        Some(dto) => Ok(Json(
            serde_json::to_value(dto).expect("CategoryDto serializes cleanly"),
        )),
        None => Err(ApiError::not_found(
            "getCategory",
            "The given category does not exist.",
        )),
    }
}
pub async fn create_category(
    State(state): State<AppState>,
    FormOrQuery(form): FormOrQuery<CategoryForm>,
) -> Result<Json<Value>, ApiError> {
    if form.name.is_empty() {
        return Err(ApiError::bad_request(
            "createCategory",
            "Category name not specified.",
        ));
    }
    let search = form.search.filter(|s| !s.is_empty());
    let pinned = form.pinned.as_deref().map(|v| v != "false" && !v.is_empty()).unwrap_or(false);
    let category_id = service::category::create(&state.db, &form.name, search.as_deref(), pinned)
        .await
        .map_err(|e| ApiError::internal("createCategory", e.to_string()))?;
    Ok(Json(json!({
        "operation": "create_category",
        "category_id": category_id,
        "success": 1,
    })))
}
pub async fn update_category(
    State(state): State<AppState>,
    Path(id): Path<String>,
    FormOrQuery(form): FormOrQuery<CategoryForm>,
) -> Result<Json<Value>, ApiError> {
    // Fetch current values to use as defaults for omitted fields.
    let existing = service::category::get(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("updateCategory", e.to_string()))?
        .ok_or_else(|| {
            ApiError::not_found("updateCategory", "The given category does not exist.")
        })?;

    let name = if form.name.is_empty() {
        existing.name.clone()
    } else {
        form.name.clone()
    };
    // If form sent no search field (None) keep existing; empty string clears it.
    let search = form.search.filter(|s| !s.is_empty()).or_else(|| {
        if existing.search.is_empty() {
            None
        } else {
            Some(existing.search.clone())
        }
    });
    let pinned = form.pinned.as_deref().map(|v| v != "false" && !v.is_empty()).unwrap_or(false);

    service::category::update(&state.db, &id, &name, search.as_deref(), pinned)
        .await
        .tag_err("updateCategory")?;

    Ok(Json(json!({
        "operation": "update_category",
        "category_id": id,
        "success": 1,
    })))
}
pub async fn delete_category(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    service::category::delete(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("deleteCategory", e.to_string()))?;
    Ok(op_success("delete_category"))
}
pub async fn add_to_category(
    State(state): State<AppState>,
    Path((id, archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    service::category::add_to_category(&state.db, &id, &archive)
        .await
        .tag_err("addToCategory")?;
    Ok(Json(json!({
        "operation": "add_to_category",
        "success": 1,
        "successMessage": format!("Added {} to Category {}!", archive, id),
    })))
}
pub async fn remove_from_category(
    State(state): State<AppState>,
    Path((id, archive)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    service::category::remove_from_category(&state.db, &id, &archive)
        .await
        .tag_err("removeFromCategory")?;
    Ok(op_success("remove_from_category"))
}
pub async fn get_bookmark_link(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let category_id = service::category::get_bookmark_link(&state.db)
        .await
        .map_err(|e| ApiError::internal("getBookmarkLink", e.to_string()))?;
    Ok(Json(json!({
        "operation": "get_bookmark_link",
        "success": 1,
        "category_id": category_id,
    })))
}
pub async fn update_bookmark_link(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    service::category::update_bookmark_link(&state.db, &id)
        .await
        .tag_err("updateBookmarkLink")?;
    Ok(Json(json!({
        "operation": "update_bookmark_link",
        "category_id": id,
        "success": 1,
    })))
}
pub async fn remove_bookmark_link(
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let category_id = service::category::remove_bookmark_link(&state.db)
        .await
        .map_err(|e| ApiError::internal("removeBookmarkLink", e.to_string()))?;
    Ok(Json(json!({
        "operation": "remove_bookmark_link",
        "category_id": category_id,
        "success": 1,
    })))
}
