//! Success envelope helpers. Error envelopes go through `crate::error::ApiError`.

use axum::Json;
use serde_json::{Value, json};

/// 200 OK envelope for endpoints without a structured response body
/// (`OperationResponse` schema in `openapi.yaml`).
pub fn op_success(operation: &'static str) -> Json<Value> {
    Json(json!({ "operation": operation, "success": 1 }))
}
