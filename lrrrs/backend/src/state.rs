use std::collections::HashSet;
use std::sync::Arc;

use axum::http::Method;
use sqlx::PgPool;

use crate::auth::{LrrConfig, VerifyCache};
use crate::config::Config;
use crate::{minion, shinobu};

#[derive(Clone)]
pub struct AppState {
    pub config: Config,
    pub db: PgPool,
    pub shinobu: Arc<shinobu::Controller>,
    pub minion: Arc<minion::Controller>,
    pub rayon: Arc<rayon::ThreadPool>,
    /// Loaded from `lrr_config` at boot. Config changes require a restart.
    pub lrr_config: LrrConfig,
    /// Argon2 PHC hash from `lrr_api_key`, or `None` in read-only mode.
    pub api_key_hash: Option<Arc<str>>,
    /// Pre-computed set of secured `(method, /api-prefixed path)` pairs.
    pub secured: Arc<HashSet<(Method, String)>>,
    /// In-memory Argon2 verify cache keyed on bearer plaintext.
    pub verify_cache: VerifyCache,
}

impl AppState {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        config: Config,
        db: PgPool,
        shinobu: Arc<shinobu::Controller>,
        minion: Arc<minion::Controller>,
        rayon: Arc<rayon::ThreadPool>,
        lrr_config: LrrConfig,
        api_key_hash: Option<Arc<str>>,
        secured: Arc<HashSet<(Method, String)>>,
    ) -> Self {
        Self {
            config,
            db,
            shinobu,
            minion,
            rayon,
            lrr_config,
            api_key_hash,
            secured,
            verify_cache: VerifyCache::new(),
        }
    }
}
