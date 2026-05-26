//! No-op task: sleeps briefly then echoes its args. Skeleton few-shot.

use std::time::Duration;

use serde_json::{Value as JsonValue, json};

use super::{Task, TaskFuture};

pub const NAME: &str = "noop";

pub struct Noop;

impl Task for Noop {
    fn name(&self) -> &'static str {
        NAME
    }

    fn run<'a>(&'a self, args: &'a JsonValue) -> TaskFuture<'a> {
        Box::pin(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            Ok(json!({ "echo": args }))
        })
    }
}
