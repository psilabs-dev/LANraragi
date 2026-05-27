//! Minion business logic.

use serde_json::{Value as JsonValue, json};
use sqlx::PgPool;

use crate::db;
use crate::minion::Controller;

#[derive(Debug)]
pub enum EnqueueError {
    UnknownTask(String),
    InvalidArgs(serde_json::Error),
    Db(sqlx::Error),
}

impl std::fmt::Display for EnqueueError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownTask(name) => write!(f, "unknown job type `{name}`"),
            Self::InvalidArgs(e) => write!(f, "invalid args JSON: {e}"),
            Self::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

impl std::error::Error for EnqueueError {}

impl From<EnqueueError> for crate::error::PendingApiError {
    fn from(e: EnqueueError) -> Self {
        use crate::error::PendingApiError;
        match e {
            EnqueueError::UnknownTask(_) | EnqueueError::InvalidArgs(_) => {
                PendingApiError::bad_request(e.to_string())
            }
            EnqueueError::Db(db) => PendingApiError::internal(db.to_string()),
        }
    }
}

pub async fn enqueue(
    pool: &PgPool,
    controller: &Controller,
    task: &str,
    args_raw: &str,
    priority: i32,
) -> Result<i64, EnqueueError> {
    if !controller.known_task(task) {
        return Err(EnqueueError::UnknownTask(task.to_string()));
    }
    let args: JsonValue =
        serde_json::from_str(args_raw).map_err(EnqueueError::InvalidArgs)?;
    db::jobs::insert(pool, task, &args, priority)
        .await
        .map_err(EnqueueError::Db)
}

pub async fn fetch_status(pool: &PgPool, id: i64) -> Result<Option<JsonValue>, sqlx::Error> {
    let Some(row) = db::jobs::fetch(pool, id).await? else {
        return Ok(None);
    };
    // `notes` is the progress payload (set via $job->note() in Perl); always empty in LRRRS
    // because we have no in-flight progress notes column.
    // `result` is the finish payload written by mark_finished (row.notes column).
    Ok(Some(json!({
        "task": row.task,
        "state": row.state,
        "notes": {},
        "result": row.notes,
        "error": row.error.as_deref().unwrap_or(""),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Verifies that fetch_status returns `result` (finish payload) and `notes: {}` (empty).
    ///
    /// Requires a live Postgres DB; skipped otherwise.
    #[tokio::test]
    #[ignore = "requires live Postgres DB (TEST_DATABASE_URL)"]
    async fn fetch_status_result_field_populated_notes_empty() {
        let db_url = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
        let pool = PgPool::connect(&db_url).await.unwrap();
        crate::db::migrate::run(&pool).await.unwrap();

        let id = db::jobs::insert(&pool, "noop", &json!([]), 0).await.unwrap();
        let finish_payload = json!({ "echo": "hello" });
        db::jobs::mark_finished(&pool, id, &finish_payload).await.unwrap();

        let status = fetch_status(&pool, id).await.unwrap().unwrap();
        assert_eq!(status["state"], "finished");
        assert_eq!(status["result"], finish_payload, "result must carry finish payload");
        assert_eq!(status["notes"], json!({}), "notes must be empty object");
    }
}

pub async fn fetch_detail(pool: &PgPool, id: i64) -> Result<Option<JsonValue>, sqlx::Error> {
    let Some(row) = db::jobs::fetch(pool, id).await? else {
        return Ok(None);
    };
    // Mojo::Minion serialises timestamps as ISO-8601 strings; the aio-lanraragi
    // Pydantic model expects `created` and `delayed` to be non-null strings.
    // LRRRS stores epoch-second integers and has no explicit delayed column
    // (jobs are never delayed), so `delayed` mirrors `created`.
    let created_str = row.created.to_string();
    let started_str = row.started.map(|t| t.to_string());
    let finished_str = row.finished.map(|t| t.to_string());
    Ok(Some(json!({
        "id": row.id,
        "task": row.task,
        "args": row.args,
        "priority": row.priority,
        "queue": "default",
        "state": row.state,
        "notes": {},
        "result": row.notes,
        "error": row.error.as_deref().unwrap_or(""),
        "attempts": 1,
        "retries": 0,
        "worker": 0,
        "children": [],
        "parents": [],
        "created": created_str,
        "delayed": created_str,
        "started": started_str,
        "finished": finished_str,
    })))
}
