//! SQL queries for the `lrr_api_key` singleton table.

use sqlx::PgPool;

/// Returns the stored Argon2 PHC hash, or `None` when no row exists (read-only
/// mode).
pub async fn load_hash(pool: &PgPool) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>("SELECT key_hash FROM lrr_api_key WHERE id = 1")
        .fetch_optional(pool)
        .await
}

/// Deletes the single row (if any). Used by `service::database::drop_database`
/// to invalidate auth as part of a full database reset.
pub async fn delete_all(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM lrr_api_key").execute(pool).await?;
    Ok(())
}

/// Inserts the hashed key only when the table is empty. No-op otherwise.
pub async fn insert_if_empty(pool: &PgPool, key_hash: &str) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO lrr_api_key (id, key_hash) VALUES (1, $1) ON CONFLICT DO NOTHING")
        .bind(key_hash)
        .execute(pool)
        .await?;
    Ok(())
}
