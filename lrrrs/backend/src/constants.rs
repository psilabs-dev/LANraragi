//! Auth and other backend-wide constants.

/// Duration a verified bearer is cached to avoid repeated Argon2 verification.
pub const VERIFY_CACHE_TTL_SECS: u64 = 60;

/// 401 response body for any unauthenticated request to a secured route.
pub const UNAUTHORIZED_BODY: &str =
    r#"{"error":"This API is protected and requires login or an API Key."}"#;
