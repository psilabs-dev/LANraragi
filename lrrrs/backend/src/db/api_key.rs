//! SQL queries for the `lrr_api_key` singleton table.

use sqlx::PgPool;

/// Returns the stored Argon2 PHC hash, or `None` when no row exists (read-only
/// mode).
pub async fn load_hash(pool: &PgPool) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>("SELECT key_hash FROM lrr_api_key WHERE id = 1")
        .fetch_optional(pool)
        .await
}

/// Inserts the hashed key only when the table is empty. No-op otherwise.
pub async fn insert_if_empty(pool: &PgPool, key_hash: &str) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;

    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM lrr_api_key WHERE id = 1)")
            .fetch_one(&mut *tx)
            .await?;

    if !exists {
        sqlx::query("INSERT INTO lrr_api_key (key_hash) VALUES ($1)")
            .bind(key_hash)
            .execute(&mut *tx)
            .await?;
    }

    tx.commit().await
}
