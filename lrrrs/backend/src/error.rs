//! Error envelope for HTTP responses.
//!
//! # Auth 401s
//!
//! Auth-failure 401 responses must NOT use `ApiError`; its `IntoResponse`
//! emits the `{operation, success, error}` envelope, which diverges from the
//! verbatim Perl body required by the auth contract. Auth middleware emits
//! `constants::UNAUTHORIZED_BODY` directly as a raw string response tuple.
//!
//! # The two-type pattern
//!
//! - [`PendingApiError`]: wire shape minus operation id. Produced by
//!   `From<DomainError>` impls in service and support modules.
//! - [`ApiError`]: wire shape with operation id. The only type that
//!   implements `IntoResponse`.
//!
//! Controllers convert via [`TagErr::tag_err`]:
//!
//! ```ignore
//! let arcid = service::archive::upload(...).await.tag_err("uploadArchive")?;
//! ```
//!
//! Bare `?` against a service error fails to compile; the conversion only
//! exists via `tag_err`, which forces the operation id to be set at every
//! wire-emitting site. Empty operation ids are impossible by construction.

use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;

/// Wire-shape error without an operation id. Produced by `From<DomainError>`
/// impls; promoted to [`ApiError`] via [`PendingApiError::tag`] or
/// [`TagErr::tag_err`].
#[derive(Debug)]
pub struct PendingApiError {
    pub status: StatusCode,
    pub message: String,
}

impl PendingApiError {
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    #[allow(dead_code)]
    pub fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: message.into(),
        }
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            message: message.into(),
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
        }
    }

    pub fn tag(self, operation: &'static str) -> ApiError {
        ApiError {
            status: self.status,
            operation,
            message: self.message,
        }
    }
}

/// Wire-shape error with operation id. The only error type that implements
/// `IntoResponse`.
#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub operation: &'static str,
    pub message: String,
}

impl ApiError {
    pub fn not_implemented(operation: &'static str) -> Self {
        Self {
            status: StatusCode::NOT_IMPLEMENTED,
            operation,
            message: "not_implemented".into(),
        }
    }

    pub fn bad_request(operation: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            operation,
            message: message.into(),
        }
    }

    pub fn internal(operation: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            operation,
            message: message.into(),
        }
    }

    pub fn not_found(operation: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            operation,
            message: message.into(),
        }
    }

    pub fn conflict(operation: &'static str, message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            operation,
            message: message.into(),
        }
    }

}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({
                "operation": self.operation,
                "success": 0,
                "error": self.message,
            })),
        )
            .into_response()
    }
}

/// Attaches the controller's operation id to an error from a service or
/// support layer, promoting [`PendingApiError`] to [`ApiError`].
pub trait TagErr<T> {
    fn tag_err(self, operation: &'static str) -> Result<T, ApiError>;
}

impl<T, E: Into<PendingApiError>> TagErr<T> for Result<T, E> {
    fn tag_err(self, operation: &'static str) -> Result<T, ApiError> {
        self.map_err(|e| e.into().tag(operation))
    }
}
