//! Database pool setup.

use sqlx::postgres::{PgPool, PgPoolOptions};

pub async fn connect(url: &str) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new().max_connections(16).connect(url).await
}
