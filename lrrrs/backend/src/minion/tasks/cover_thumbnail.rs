//! Cover-thumbnail generation stub. Returns `{generated: false}`; not yet implemented.

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

pub const NAME: &str = "cover_thumbnail";

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
