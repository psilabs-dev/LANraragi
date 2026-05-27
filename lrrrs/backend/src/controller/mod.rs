pub mod archive;
pub mod category;
pub mod database;
pub mod minion;
pub mod misc;
pub mod opds;
pub mod plugins;
pub mod search;
pub mod shinobu;
pub mod stamps;
pub mod tankoubon;

use axum::{
    extract::{FromRequest, Query, Request},
    http::header,
};
use serde::de::DeserializeOwned;

use crate::error::ApiError;

/// Extractor that reads params from the URL-encoded body when
/// `Content-Type: application/x-www-form-urlencoded` is present, or from
/// the query string otherwise. The LRR frontend sends params as a query string
/// (no body, no Content-Type), while aiohttp sends a URL-encoded body.
pub struct FormOrQuery<T>(pub T);

impl<T, S> FromRequest<S> for FormOrQuery<T>
where
    T: DeserializeOwned + Default + Send + 'static,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let is_form = req
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|ct| ct.starts_with("application/x-www-form-urlencoded"))
            .unwrap_or(false);

        if is_form {
            let form = axum::extract::Form::<T>::from_request(req, state)
                .await
                .map_err(|e| ApiError::bad_request("formExtract", &e.to_string()))?;
            Ok(FormOrQuery(form.0))
        } else {
            let query = Query::<T>::from_request(req, state)
                .await
                .map_err(|e| ApiError::bad_request("queryExtract", &e.to_string()))?;
            Ok(FormOrQuery(query.0))
        }
    }
}
