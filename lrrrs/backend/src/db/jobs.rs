//! Minion job queue SQL.

use serde_json::Value as JsonValue;
use sqlx::PgPool;

#[derive(sqlx::FromRow)]
pub struct JobRow {
    pub id: i64,
    pub task: String,
    pub args: JsonValue,
    pub priority: i32,
    pub state: String,
    pub notes: JsonValue,
    pub error: Option<String>,
    pub created: i64,
    pub started: Option<i64>,
    pub finished: Option<i64>,
}

pub async fn insert(
    pool: &PgPool,
    task: &str,
    args: &JsonValue,
    priority: i32,
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar(
        r#"
        INSERT INTO lrr_jobs (task, args, priority)
        VALUES ($1, $2, $3)
        RETURNING id
        "#,
    )
    .bind(task)
    .bind(args)
    .bind(priority)
    .fetch_one(pool)
    .await
}

pub async fn claim_next(pool: &PgPool) -> Result<Option<JobRow>, sqlx::Error> {
    sqlx::query_as::<_, JobRow>(
        r#"
        UPDATE lrr_jobs
        SET state = 'active', started = EXTRACT(EPOCH FROM now())::BIGINT
        WHERE id = (
            SELECT id FROM lrr_jobs
            WHERE state = 'inactive'
            ORDER BY priority DESC, id ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        RETURNING id, task, args, priority, state::TEXT, notes, error, created, started, finished
        "#,
    )
    .fetch_optional(pool)
    .await
}

pub async fn mark_finished(
    pool: &PgPool,
    id: i64,
    notes: &JsonValue,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        UPDATE lrr_jobs
        SET state = 'finished', finished = EXTRACT(EPOCH FROM now())::BIGINT, notes = $2
        WHERE id = $1
        "#,
    )
    .bind(id)
    .bind(notes)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn mark_failed(pool: &PgPool, id: i64, error: &str) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        UPDATE lrr_jobs
        SET state = 'failed', finished = EXTRACT(EPOCH FROM now())::BIGINT, error = $2
        WHERE id = $1
        "#,
    )
    .bind(id)
    .bind(error)
    .execute(pool)
    .await?;
    Ok(())
}

/// Marks all `'active'` job rows as `'failed'` with an orphan-sweep note.
///
/// Called once at startup before the worker loop begins. Safe under single-instance
/// deployment (LRRRS architecture): any `'active'` row at startup was abandoned by
/// the previous process and cannot be reclaimed by the claim_next query.
pub async fn sweep_orphaned_active(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(
        r#"
        UPDATE lrr_jobs
        SET state = 'failed',
            finished = EXTRACT(EPOCH FROM now())::BIGINT,
            error = 'orphan sweep: job was active at startup and has been marked failed'
        WHERE state = 'active'
        "#,
    )
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

pub async fn fetch(pool: &PgPool, id: i64) -> Result<Option<JobRow>, sqlx::Error> {
    sqlx::query_as::<_, JobRow>(
        r#"
        SELECT id, task, args, priority, state::TEXT, notes, error, created, started, finished
        FROM lrr_jobs
        WHERE id = $1
        "#,
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Verifies that sweep_orphaned_active transitions 'active' rows to 'failed'.
    ///
    /// Requires a live Postgres DB; skipped otherwise.
    #[tokio::test]
    #[ignore = "requires live Postgres DB (TEST_DATABASE_URL)"]
    async fn sweep_orphaned_active_transitions_row() {
        let db_url = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
        let pool = PgPool::connect(&db_url).await.unwrap();
        crate::db::migrate::run(&pool).await.unwrap();

        // Insert a row then manually force it to 'active' to simulate orphan state.
        let id = insert(&pool, "noop", &json!([]), 0).await.unwrap();
        sqlx::query("UPDATE lrr_jobs SET state = 'active' WHERE id = $1")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();

        let swept = sweep_orphaned_active(&pool).await.unwrap();
        assert!(swept >= 1, "at least one row must be swept");

        let row = fetch(&pool, id).await.unwrap().unwrap();
        assert_eq!(row.state, "failed", "orphan row must be marked failed after sweep");
    }
}
