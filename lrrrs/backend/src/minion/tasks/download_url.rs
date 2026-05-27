//! Download-URL task: fetches a remote URL and ingests the result via the
//! archive upload pipeline.
//!
//! args JSON array: ["<url>", "<catid_or_null>"]
//!
//! Currently a stub; the HTTP fetch + ingest are not yet implemented.

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

pub const NAME: &str = "download_url";

pub struct DownloadUrl;

impl Task for DownloadUrl {
    fn name(&self) -> &'static str {
        NAME
    }
    fn run<'a>(&'a self, args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            let url = args.get(0).and_then(|v| v.as_str()).unwrap_or("");
            Ok(json!({ "url": url, "downloaded": false }))
        })
    }
}
