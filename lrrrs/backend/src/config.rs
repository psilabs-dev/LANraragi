use std::path::PathBuf;
use std::{env, net::SocketAddr};

use tracing_subscriber::{EnvFilter, fmt};

#[derive(Clone, Debug)]
pub struct Config {
    pub bind_addr: SocketAddr,
    pub postgres_url: String,
    pub content_dir: PathBuf,
    pub rayon_threads: usize,
}

impl Config {
    pub fn from_env() -> Result<Self, std::net::AddrParseError> {
        let bind_addr = env::var("LRR_BIND_ADDR")
            .unwrap_or_else(|_| "0.0.0.0:3000".to_string())
            .parse()?;
        let postgres_url = postgres_url_from_env();
        let content_dir = env::var("LRR_CONTENT_DIR")
            .map_or_else(|_| PathBuf::from("./content"), PathBuf::from);
        let rayon_threads = env::var("LRR_RAYON_THREADS")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .unwrap_or_else(num_cpus::get);
        Ok(Self {
            bind_addr,
            postgres_url,
            content_dir,
            rayon_threads,
        })
    }

    pub fn initialize_tracing() {
        let env_filter = EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new("lrrrs_backend=info,axum=info,sqlx=warn"));

        fmt().with_env_filter(env_filter).init();
    }
}

fn postgres_url_from_env() -> String {
    let host = env::var("LRR_POSTGRES_HOST").unwrap_or_else(|_| "localhost".to_string());
    let port = env::var("LRR_POSTGRES_PORT").unwrap_or_else(|_| "5432".to_string());
    let user = env::var("LRR_POSTGRES_USER").unwrap_or_else(|_| "lanraragi".to_string());
    let password = env::var("LRR_POSTGRES_PASSWORD").unwrap_or_else(|_| "lanraragi".to_string());
    let db = env::var("LRR_POSTGRES_DB").unwrap_or_else(|_| "lanraragi".to_string());
    format!("postgres://{user}:{password}@{host}:{port}/{db}")
}
