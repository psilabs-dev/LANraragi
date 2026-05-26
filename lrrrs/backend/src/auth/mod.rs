//! Auth module: bootstrap, middleware, route sets, and verify cache.
//!
//! Public surface consumed by `main.rs`, `app.rs`, and `state.rs`:
//! - `seed_from_env` — boot-time API key seeding.
//! - `build_secured_set` — constructs the `HashSet<(Method, String)>` at boot.
//! - `LrrConfig` — re-exported from `db::config` for `AppState`.
//! - `VerifyCache` — re-exported from `cache` for `AppState`.
//! - `middleware::layer` — axum middleware function.

pub mod cache;
pub mod middleware;
pub mod routes;
pub mod seed;

pub use cache::VerifyCache;
pub use crate::db::config::LrrConfig;
pub use routes::build_secured_set;
pub use seed::seed_from_env;
