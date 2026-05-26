//! Filemap SQL queries.

use sqlx::{PgExecutor, postgres::PgQueryResult};

pub async fn insert<'e, E>(executor: E, path: &str, arcid: &str) -> Result<PgQueryResult, sqlx::Error>
where
    E: PgExecutor<'e>,
{
    sqlx::query(
        r#"
        INSERT INTO lrr_filemap (path, arcid)
        VALUES ($1, $2)
        ON CONFLICT (path) DO UPDATE SET arcid = EXCLUDED.arcid
        "#,
    )
    .bind(path)
    .bind(arcid)
    .execute(executor)
    .await
}

#[allow(dead_code)]
pub async fn lookup_by_path<'e, E>(executor: E, path: &str) -> Result<Option<String>, sqlx::Error>
where
    E: PgExecutor<'e>,
{
    sqlx::query_scalar("SELECT arcid FROM lrr_filemap WHERE path = $1")
        .bind(path)
        .fetch_optional(executor)
        .await
}

#[allow(dead_code)]
pub async fn lookup_paths_by_arcid<'e, E>(
    executor: E,
    arcid: &str,
) -> Result<Vec<String>, sqlx::Error>
where
    E: PgExecutor<'e>,
{
    sqlx::query_scalar("SELECT path FROM lrr_filemap WHERE arcid = $1")
        .bind(arcid)
        .fetch_all(executor)
        .await
}
