//! OPDS catalog handlers.
//!
//! OPDS endpoints return `application/atom+xml;profile=opds-catalog` rather
//! than JSON. The response is a raw `(StatusCode, [(HeaderName, &str)], String)`
//! tuple which axum renders without the JSON envelope.
//!
//! The OPDS-PSE page endpoint (`getOpdsPage`) streams the raw image bytes for
//! the requested page number. In v0, page extraction relies on the temp cache
//! being warm (i.e., `getPage` was called first). If the page is not yet
//! extracted this handler returns 404.

use axum::{
    extract::{Path, Query, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;

use crate::error::ApiError;
use crate::service;
use crate::state::AppState;

const OPDS_CONTENT_TYPE: &str = "application/atom+xml;profile=opds-catalog";

fn opds_response(body: String) -> Response {
    (
        StatusCode::OK,
        [(
            header::CONTENT_TYPE,
            HeaderValue::from_static(OPDS_CONTENT_TYPE),
        )],
        body,
    )
        .into_response()
}

#[derive(Deserialize)]
pub struct CatalogParams {
    #[serde(default)]
    category: String,
    #[serde(default)]
    start: usize,
    key: Option<String>,
}
pub async fn get_opds_catalog(
    State(state): State<AppState>,
    Query(params): Query<CatalogParams>,
) -> Result<Response, ApiError> {
    let api_key_query = params
        .key
        .as_deref()
        .map_or_else(String::new, |k| format!("?key={}", service::opds::xml_escape(k)));
    let api_key_and = params
        .key
        .as_deref()
        .map_or_else(String::new, |k| format!("&amp;key={}", service::opds::xml_escape(k)));

    let pagesize = state.lrr_config.pagesize.max(1) as usize;
    let mut entries = service::opds::fetch_catalog_entries(
        &state.db,
        &params.category,
        params.start,
        pagesize,
    )
    .await
    .map_err(|e| ApiError::internal("getOpdsCatalog", e.to_string()))?;

    // Sort alphabetically by title (case-insensitive), matching Perl's sort block.
    entries.sort_by(|a, b| a.title.to_ascii_lowercase().cmp(&b.title.to_ascii_lowercase()));

    let cat_rows = service::opds::fetch_categories(&state.db)
        .await
        .map_err(|e| ApiError::internal("getOpdsCatalog", e.to_string()))?;

    // Build (CategoryRow, Option<count>) pairs. Static categories (no search
    // string) get a count; dynamic ones (have a search string) do not.
    let mut cats_with_counts = Vec::with_capacity(cat_rows.len());
    for cat in cat_rows {
        let count = if cat.search.is_empty() {
            let n = service::opds::fetch_static_category_count(&state.db, &cat.catid)
                .await
                .map_err(|e| ApiError::internal("getOpdsCatalog", e.to_string()))?;
            Some(n)
        } else {
            None
        };
        cats_with_counts.push((cat, count));
    }
    // Sort categories alphabetically by name.
    cats_with_counts
        .sort_by(|(a, _), (b, _)| a.name.to_ascii_lowercase().cmp(&b.name.to_ascii_lowercase()));

    let xml = service::opds::render_catalog(
        "LANraragi",
        "",
        env!("CARGO_PKG_VERSION"),
        &params.category,
        params.start,
        &entries,
        &cats_with_counts,
        &api_key_query,
        &api_key_and,
    );

    Ok(opds_response(xml))
}
pub async fn get_opds_item(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<KeyParam>,
) -> Result<Response, ApiError> {
    let api_key_query = params
        .key
        .as_deref()
        .map_or_else(String::new, |k| format!("?key={}", service::opds::xml_escape(k)));
    let api_key_and = params
        .key
        .as_deref()
        .map_or_else(String::new, |k| format!("&amp;key={}", service::opds::xml_escape(k)));

    let entry = service::opds::fetch_opds_entry(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("getOpdsItem", e.to_string()))?
        .ok_or_else(|| ApiError::not_found("getOpdsItem", "Archive not found."))?;

    let xml = service::opds::render_item(
        "LANraragi",
        env!("CARGO_PKG_VERSION"),
        &entry,
        &api_key_query,
        &api_key_and,
    );

    Ok(opds_response(xml))
}

#[derive(Deserialize)]
pub struct KeyParam {
    key: Option<String>,
}

#[derive(Deserialize)]
pub struct PageParam {
    #[serde(default = "default_page")]
    page: usize,
    // Accepted from OPDS clients that pass ?key= for auth; not used after
    // extraction since the page is served from the filesystem temp cache.
    #[allow(dead_code)]
    key: Option<String>,
}

fn default_page() -> usize {
    1
}
pub async fn get_opds_page(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<PageParam>,
) -> Result<Response, ApiError> {
    // Resolve the archive path and pagecount together from the filemap.
    let (archive_path, pagecount) = crate::db::archive::get_path_and_pagecount(&state.db, &id)
        .await
        .map_err(|e| ApiError::internal("getOpdsPage", e.to_string()))?
        .ok_or_else(|| ApiError::not_found("getOpdsPage", "Archive not found."))?;

    let page = params.page.max(1).min(pagecount as usize);

    // Look for an already-extracted page under temp/<id>/.
    let temp_dir = state.config.temp_dir.join(&id);

    // List extracted files in numeric order (same order as get_filelist would).
    let image_path = find_extracted_page(&temp_dir, page).await
        .map_err(|e| ApiError::internal("getOpdsPage", e.to_string()))?
        .ok_or_else(|| {
            // Page not yet extracted: client should call getPage first.
            ApiError::not_found("getOpdsPage", "Page not extracted yet. Call /api/archives/{id}/page first.")
        })?;

    let _ = archive_path; // path resolved but page served from temp cache

    let bytes = tokio::fs::read(&image_path)
        .await
        .map_err(|e| ApiError::internal("getOpdsPage", e.to_string()))?;

    let mime = mime_from_path(&image_path);

    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, HeaderValue::from_str(mime).unwrap_or(HeaderValue::from_static("application/octet-stream")))],
        bytes,
    )
        .into_response())
}

// Helpers

async fn find_extracted_page(
    temp_dir: &std::path::Path,
    page: usize,
) -> Result<Option<std::path::PathBuf>, std::io::Error> {
    if !temp_dir.exists() {
        return Ok(None);
    }

    let mut entries = tokio::fs::read_dir(temp_dir).await?;
    let mut names: Vec<String> = Vec::new();
    while let Some(e) = entries.next_entry().await? {
        let p = e.path();
        if p.is_file() {
            if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                names.push(name.to_string());
            }
        }
    }
    // Use the same natural-sort + cover/credit ordering as the archive page list
    // so OPDS-PSE page N matches getFiles page N (not lexicographic).
    crate::service::archive::sort_filelist(&mut names);

    Ok(names
        .into_iter()
        .nth(page.saturating_sub(1))
        .map(|name| temp_dir.join(name)))
}

fn mime_from_path(path: &std::path::Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png")                => "image/png",
        Some("gif")                => "image/gif",
        Some("webp")               => "image/webp",
        _                          => "application/octet-stream",
    }
}

