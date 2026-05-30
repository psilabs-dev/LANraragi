//! Regen-thumbnails task: regenerates missing or all cover thumbnails for every
//! archive in the library.
//!
//! args JSON array: ["<thumbdir>", <force: bool>]
//!
//! Not yet implemented. Real generation will call into `service::thumbnail`
//! (archive extraction + WebP conversion via the `image` crate) via the Rayon
//! pool (`support::cpu::run`) so that image-decode work does not block Tokio
//! worker threads.

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

// `regen_all_thumbnails` per the queueMinionJob enum in openapi.yaml.
pub const NAME: &str = "regen_all_thumbnails";

pub struct RegenThumbs;

impl Task for RegenThumbs {
    fn name(&self) -> &'static str {
        NAME
    }
    fn run<'a>(&'a self, args: &'a JsonValue, _rayon: &'a rayon::ThreadPool) -> TaskFuture<'a> {
        Box::pin(async move {
            let force = args.get(1).and_then(|v| v.as_bool()).unwrap_or(false);
            Ok(json!({ "force": force, "generated": 0 }))
        })
    }
}
