//! build_stat_hashes task: no-op for Postgres (indexes maintained automatically).

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

pub const NAME: &str = "build_stat_hashes";

pub struct BuildStatHashes;

impl Task for BuildStatHashes {
    fn name(&self) -> &'static str {
        NAME
    }
    fn run<'a>(&'a self, _args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            // No-op for Postgres: stat indexes are maintained automatically by
            // the database. This task exists only so callers can queue it and
            // wait for completion without receiving "unknown job type".
            Ok(json!({ "message": "build_stat_hashes: no-op for Postgres" }))
        })
    }
}
