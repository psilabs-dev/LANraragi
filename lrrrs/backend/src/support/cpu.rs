//! Tokio → Rayon bridge for CPU-bound work.

use std::any::Any;
use std::fmt;
use std::panic::UnwindSafe;

#[derive(Debug)]
pub enum CpuTaskError {
    Panic(String),
    WorkerDropped,
}

impl fmt::Display for CpuTaskError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Panic(msg) => write!(f, "rayon worker panicked: {msg}"),
            Self::WorkerDropped => write!(f, "rayon worker dropped result channel without sending"),
        }
    }
}

impl std::error::Error for CpuTaskError {}

impl From<CpuTaskError> for crate::error::PendingApiError {
    fn from(e: CpuTaskError) -> Self {
        crate::error::PendingApiError::internal(e.to_string())
    }
}

/// Runs `f` on the supplied Rayon pool and awaits the result. Panics inside
/// `f` are caught and returned as `CpuTaskError::Panic` so worker faults do
/// not propagate out of the Rayon thread.
pub async fn run<F, T>(pool: &rayon::ThreadPool, f: F) -> Result<T, CpuTaskError>
where
    F: FnOnce() -> T + Send + UnwindSafe + 'static,
    T: Send + 'static,
{
    let (tx, rx) = tokio::sync::oneshot::channel();
    pool.spawn(move || {
        let result = std::panic::catch_unwind(f);
        let _ = tx.send(result);
    });
    match rx.await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(panic)) => Err(CpuTaskError::Panic(format_panic(&panic))),
        Err(_) => Err(CpuTaskError::WorkerDropped),
    }
}

fn format_panic(panic: &(dyn Any + Send)) -> String {
    if let Some(s) = panic.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else {
        "non-string panic payload".to_string()
    }
}
