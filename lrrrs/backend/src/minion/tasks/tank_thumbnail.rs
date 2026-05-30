//! Tankoubon cover-thumbnail generation stub.
//!
//! Generates a cover thumbnail for a tankoubon by extracting the first page
//! of the first archive in the tank. Returns `{generated: false}`; not yet implemented.

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

// `tank_thumbnail_task` per the queueMinionJob enum in openapi.yaml.
pub const NAME: &str = "tank_thumbnail_task";

pub struct TankThumbnail;

impl Task for TankThumbnail {
    fn name(&self) -> &'static str {
        NAME
    }

    fn run<'a>(&'a self, args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            let tankid = args.get(0).and_then(|v| v.as_str()).unwrap_or("");
            Ok(json!({ "tankid": tankid, "generated": false }))
        })
    }
}
