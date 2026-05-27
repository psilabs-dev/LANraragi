//! Per-page thumbnail generation task.
//!
//! args JSON array: [arcid: String, page: i32, force: bool]
//!
//! - `page > 0`: generate the thumbnail for that specific page only.
//! - `page == 0`: generate thumbnails for all pages in the archive.
//! - `force`: when true, regenerate even if the thumbnail already exists.
//!
//! Not yet implemented. The task is registered so that enqueued jobs are dispatched
//! and logged rather than silently accumulating as un-dispatchable rows in lrr_jobs.

use serde_json::{Value as JsonValue, json};
use tracing::info;

use super::{Task, TaskFuture};

pub const NAME: &str = "page_thumbnails";

pub struct PageThumbnail;

impl Task for PageThumbnail {
    fn name(&self) -> &'static str {
        NAME
    }

    fn run<'a>(&'a self, args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            let arcid = args.get(0).and_then(|v| v.as_str()).unwrap_or("");
            let page = args.get(1).and_then(|v| v.as_i64()).unwrap_or(0);
            let force = args.get(2).and_then(|v| v.as_bool()).unwrap_or(false);
            info!(arcid, page, force, "page_thumbnails task fired (stub)");
            Ok(json!({ "arcid": arcid, "page": page, "force": force, "generated": false }))
        })
    }
}
