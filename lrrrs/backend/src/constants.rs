//! Auth and other backend-wide constants.

/// Duration a verified bearer is cached to avoid repeated Argon2 verification.
pub const VERIFY_CACHE_TTL_SECS: u64 = 60;

/// Max distinct bearer plaintexts retained by the verify cache. Bounds memory
/// under adversarial input (a stream of distinct keys evicts LRU-first).
pub const VERIFY_CACHE_CAPACITY: usize = 1024;

/// 401 response body for any unauthenticated request to a secured route.
pub const UNAUTHORIZED_BODY: &str =
    r#"{"error":"This API is protected and requires login or an API Key."}"#;
