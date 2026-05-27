//! SQL queries for the `lrr_config` singleton table.

use sqlx::PgPool;

/// Mirror of the boot-loaded subset of the `lrr_config` row. All fields here
/// are non-nullable (migration supplies defaults and a pre-inserted row).
/// Re-exported via `auth::LrrConfig` for use in `AppState`.
///
/// `bookmark_link` (in the SQL schema) is intentionally omitted: it changes
/// at runtime via the category controller and is queried per-request by
/// `db::category`, so it does not belong in the boot-loaded snapshot.
///
/// `excluded_namespaces` is intentionally omitted: it is live-read per-request
/// via `load_excluded_namespaces` so that config changes are visible without restart.
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct LrrConfig {
    pub nofunmode: bool,
    pub enablecors: bool,
    pub authprogress: bool,
    pub localprogress: bool,
    pub pagesize: i32,
}

/// Loads the singleton config row. The migration guarantees exactly one row
/// with `id = 1`; `fetch_one` fails fast if the invariant is broken.
pub async fn load(pool: &PgPool) -> Result<LrrConfig, sqlx::Error> {
    sqlx::query_as::<_, LrrConfig>(
        "SELECT nofunmode, enablecors, authprogress, localprogress, pagesize \
         FROM lrr_config WHERE id = 1",
    )
    .fetch_one(pool)
    .await
}

/// Loads only the `excluded_namespaces` column from lrr_config.
///
/// Live-read so that config changes made via the Postgres admin interface are
/// visible without a restart.
pub async fn load_excluded_namespaces(pool: &PgPool) -> Result<String, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT excluded_namespaces FROM lrr_config WHERE id = 1",
    )
    .fetch_one(pool)
    .await
}
