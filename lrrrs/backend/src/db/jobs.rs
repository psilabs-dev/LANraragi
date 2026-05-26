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
