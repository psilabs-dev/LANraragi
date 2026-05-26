mod app;
mod auth;
mod config;
mod constants;
mod controller;
mod db;
mod error;
mod minion;
mod openapi;
mod service;
mod shinobu;
mod state;
mod support;

use std::sync::Arc;

use tokio::{net::TcpListener, signal};
use tracing::info;

use crate::{app::build_app, config::Config, state::AppState};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = Config::from_env()?;
    Config::initialize_tracing();

    info!("connecting to postgres");
    let pool = crate::db::pool::connect(&config.postgres_url).await?;
    info!("running database migrations");
    crate::db::migrate::run(&pool).await?;

    auth::seed_from_env(&pool).await?;

    let lrr_config = crate::db::config::load(&pool).await?;
    let api_key_hash: Option<Arc<str>> = crate::db::api_key::load_hash(&pool)
        .await?
        .map(|s| Arc::from(s.as_str()));
    let secured = Arc::new(auth::build_secured_set(&lrr_config));

    let shinobu = std::sync::Arc::new(crate::shinobu::Controller::new());
    let initial_pid = shinobu.start().await;
    info!("shinobu watcher started (pid={initial_pid})");

    let minion = std::sync::Arc::new(crate::minion::Controller::new());
    minion.start(pool.clone()).await;
    info!("minion worker started");

    let rayon = std::sync::Arc::new(
        rayon::ThreadPoolBuilder::new()
            .num_threads(config.rayon_threads)
            .thread_name(|i| format!("lrrrs-rayon-{i}"))
            .build()?,
    );
    info!("rayon pool initialised (threads={})", config.rayon_threads);

    let app_state = AppState::new(
        config.clone(),
        pool,
        shinobu.clone(),
        minion.clone(),
        rayon,
        lrr_config,
        api_key_hash,
        secured,
    );
    let app = build_app(app_state);

    let listener = TcpListener::bind(config.bind_addr).await?;
    info!("starting lrrrs backend on {}", config.bind_addr);

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    minion.stop().await;
    shinobu.stop().await;

    Ok(())
}

async fn shutdown_signal() {
    if let Err(error) = signal::ctrl_c().await {
        tracing::warn!("failed to install ctrl-c handler: {error}");
    }
}
