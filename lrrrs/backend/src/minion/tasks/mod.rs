//! Task trait + registry for the minion worker.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde_json::Value as JsonValue;

pub mod cover_thumbnail;
pub mod noop;

pub type TaskResult = Result<JsonValue, String>;
pub type TaskFuture<'a> = Pin<Box<dyn Future<Output = TaskResult> + Send + 'a>>;

pub trait Task: Send + Sync {
    fn name(&self) -> &'static str;
    fn run<'a>(&'a self, args: &'a JsonValue) -> TaskFuture<'a>;
}

#[derive(Default)]
pub struct Registry {
    by_name: HashMap<&'static str, Arc<dyn Task>>,
}

impl Registry {
    pub fn with_defaults() -> Self {
        let mut r = Self::default();
        r.register(Arc::new(noop::Noop));
        r.register(Arc::new(cover_thumbnail::CoverThumbnail));
        r
    }

    pub fn register(&mut self, task: Arc<dyn Task>) {
        self.by_name.insert(task.name(), task);
    }

    pub fn get(&self, name: &str) -> Option<Arc<dyn Task>> {
        self.by_name.get(name).cloned()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.by_name.contains_key(name)
    }
}
