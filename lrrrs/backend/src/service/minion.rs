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
    Ok(Some(json!({
        "task": row.task,
        "state": row.state,
        "notes": row.notes,
        "error": row.error,
    })))
}

pub async fn fetch_detail(pool: &PgPool, id: i64) -> Result<Option<JsonValue>, sqlx::Error> {
    let Some(row) = db::jobs::fetch(pool, id).await? else {
        return Ok(None);
    };
    Ok(Some(json!({
        "id": row.id,
        "task": row.task,
        "args": row.args,
        "priority": row.priority,
        "state": row.state,
        "notes": row.notes,
        "error": row.error,
        "created": row.created,
        "started": row.started,
        "finished": row.finished,
    })))
}
