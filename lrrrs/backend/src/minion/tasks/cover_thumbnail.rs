//! Cover-thumbnail generation stub. Returns `{generated: false}` until the
//! `image` crate is wired in.

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

pub const NAME: &str = "cover_thumbnail";

pub struct CoverThumbnail;

impl Task for CoverThumbnail {
    fn name(&self) -> &'static str {
        NAME
    }

    fn run<'a>(&'a self, args: &'a JsonValue) -> TaskFuture<'a> {
        Box::pin(async move {
            Ok(json!({ "arcid": args.get(0), "generated": false }))
        })
    }
}
