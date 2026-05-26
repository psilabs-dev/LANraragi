//! In-memory Argon2 verify cache.
//!
//! Keys: bearer plaintext. Values: `(expiration, valid)`. Both valid and
//! invalid verification outcomes are cached; the `valid` flag distinguishes
//! them at read time so an invalid cache hit does not pass auth. No background
//! sweeper — stale entries are evicted at read time.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::RwLock;

use crate::constants::VERIFY_CACHE_TTL_SECS;

/// Thread-safe verify cache. Cheaply cloned via the inner `Arc`.
#[derive(Clone, Default)]
pub struct VerifyCache(Arc<RwLock<HashMap<String, (Instant, bool)>>>);

impl VerifyCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the cached verification result for `plaintext`:
    /// - `Some(true)` — recently verified valid; caller may pass the request.
    /// - `Some(false)` — recently verified invalid; caller should 401 without
    ///   re-running Argon2.
    /// - `None` — no entry or entry expired; caller must run Argon2.
    pub async fn get(&self, plaintext: &str) -> Option<bool> {
        self.0
            .read()
            .await
            .get(plaintext)
            .and_then(|(exp, valid)| (Instant::now() < *exp).then_some(*valid))
    }

    /// Records a verify outcome for `plaintext`, expiring after
    /// `VERIFY_CACHE_TTL_SECS`.
    pub async fn insert(&self, plaintext: String, valid: bool) {
        let exp = Instant::now() + Duration::from_secs(VERIFY_CACHE_TTL_SECS);
        self.0.write().await.insert(plaintext, (exp, valid));
    }
}
