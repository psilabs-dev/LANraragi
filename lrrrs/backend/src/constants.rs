//! Auth and other backend-wide constants.
//!
//! Rules and rationale live in `design.md` ("Auth (resolved)"); this file
//! only holds the values. New auth magic numbers go here so a future grep
//! finds them next to the others.

/// Duration a verified bearer is cached to avoid repeated Argon2 verification.
pub const VERIFY_CACHE_TTL_SECS: u64 = 60;

/// 401 response body for any unauthenticated request to a secured route.
/// Verbatim match with Perl LANraragi (Controller/Login.pm:64-67).
pub const UNAUTHORIZED_BODY: &str =
    r#"{"error":"This API is protected and requires login or an API Key."}"#;
