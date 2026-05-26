//! sqlx migration entrypoints.

use sqlx::PgPool;

pub async fn run(pool: &PgPool) -> Result<(), sqlx::migrate::MigrateError> {
    sqlx::migrate!("./migrations").run(pool).await
}
