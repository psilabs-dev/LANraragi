//! Cover-thumbnail generation stub. Returns `{generated: false}`; not yet implemented.

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

// `thumbnail_task` per the queueMinionJob enum in openapi.yaml (cover thumbnail).
pub const NAME: &str = "thumbnail_task";

pub struct CoverThumbnail;

impl Task for CoverThumbnail {
    fn name(&self) -> &'static str {
        NAME
    }

    fn run<'a>(&'a self, args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            let arcid = args.get(0).and_then(|v| v.as_str()).unwrap_or("");
            Ok(json!({ "arcid": arcid, "generated": false }))
        })
    }
}
