//! SQL queries for the `lrr_config` singleton table.

use sqlx::PgPool;

/// Mirror of the `lrr_config` row. All fields are non-nullable (migration
/// supplies defaults and a pre-inserted row). Re-exported via `auth::LrrConfig`
/// for use in `AppState`.
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct LrrConfig {
    pub nofunmode: bool,
    pub enablecors: bool,
    pub authprogress: bool,
    pub localprogress: bool,
    pub disableopenapi: bool,
    pub pagesize: i32,
}

/// Loads the singleton config row. The migration guarantees exactly one row
/// with `id = 1`; `fetch_one` fails fast if the invariant is broken.
pub async fn load(pool: &PgPool) -> Result<LrrConfig, sqlx::Error> {
    sqlx::query_as::<_, LrrConfig>(
        "SELECT nofunmode, enablecors, authprogress, localprogress, disableopenapi, pagesize \
         FROM lrr_config WHERE id = 1",
    )
    .fetch_one(pool)
    .await
}
