//! In-memory Argon2 verify cache.
//!
//! Keys: bearer plaintext. Values: `(expiration, valid)`. Both valid and
//! invalid verification outcomes are cached; the `valid` flag distinguishes
//! them at read time so an invalid cache hit does not pass auth.
//!
//! Bounded by an LRU with capacity [`VERIFY_CACHE_CAPACITY`]: at capacity the
//! least-recently-used entry is evicted, so a stream of distinct
//! (e.g. attacker-supplied) keys cannot grow the map without bound. Entries
//! also lapse after [`VERIFY_CACHE_TTL_SECS`]; a lapsed entry reads as `None`
//! (forcing a re-verify) and is overwritten on its next insert.

use std::num::NonZeroUsize;
use std::sync::Arc;
use std::time::{Duration, Instant};

use lru::LruCache;
use tokio::sync::Mutex;

use crate::constants::{VERIFY_CACHE_CAPACITY, VERIFY_CACHE_TTL_SECS};

/// Thread-safe bounded verify cache. Cheaply cloned via the inner `Arc`.
#[derive(Clone)]
pub struct VerifyCache(Arc<Mutex<LruCache<String, (Instant, bool)>>>);

impl Default for VerifyCache {
    fn default() -> Self {
        let cap = NonZeroUsize::new(VERIFY_CACHE_CAPACITY)
            .expect("VERIFY_CACHE_CAPACITY must be non-zero");
        Self(Arc::new(Mutex::new(LruCache::new(cap))))
    }
}

impl VerifyCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the cached verification result for `plaintext`:
    /// - `Some(true)`: recently verified valid; caller may pass the request.
    /// - `Some(false)`: recently verified invalid; caller should 401 without
    ///   re-running Argon2.
    /// - `None`: no entry or entry expired; caller must run Argon2.
    pub async fn get(&self, plaintext: &str) -> Option<bool> {
        // get refreshes LRU recency (needs &mut), so the live key survives a churn
        // of distinct keys — hence Mutex rather than RwLock.
        let mut guard = self.0.lock().await;
        match guard.get(plaintext) {
            Some(&(exp, valid)) if Instant::now() < exp => Some(valid),
            _ => None,
        }
    }

    /// Records a verify outcome for `plaintext`, expiring after
    /// `VERIFY_CACHE_TTL_SECS`. Evicts the least-recently-used entry at capacity.
    pub async fn insert(&self, plaintext: String, valid: bool) {
        let exp = Instant::now() + Duration::from_secs(VERIFY_CACHE_TTL_SECS);
        self.0.lock().await.put(plaintext, (exp, valid));
    }

    /// Removes all cached verify entries. Called after drop_database so that a
    /// previously-valid bearer plaintext no longer passes auth (the key row is gone).
    pub async fn clear(&self) {
        self.0.lock().await.clear();
    }
}
