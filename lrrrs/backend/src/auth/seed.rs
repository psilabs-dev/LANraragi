//! Bootstrap: seed `lrr_api_key` from `LRR_API_KEY` env on first boot.
//!
//! - env set + table empty: hash with `Argon2::default()`, insert.
//! - env set + table populated: ignore env (DB wins).
//! - env unset + table empty: read-only mode; a `tracing::warn!` is
//!   emitted at startup so the read-only posture is visible in logs.
//! - env unset + table populated: use DB.

use argon2::{
    Argon2, PasswordHasher,
    password_hash::{rand_core::OsRng, SaltString},
};

pub async fn seed_from_env(pool: &sqlx::PgPool) -> Result<(), sqlx::Error> {
    let env_key = std::env::var("LRR_API_KEY").ok();

    // Determine whether the table already has a row.
    let existing = crate::db::api_key::load_hash(pool).await?;

    match (env_key, existing) {
        (Some(plaintext), None) => {
            // env set + table empty: hash and insert.
            let salt = SaltString::generate(&mut OsRng);
            let hash = Argon2::default()
                .hash_password(plaintext.as_bytes(), &salt)
                .expect("argon2 hash failed")
                .to_string();
            tracing::info!("seeding lrr_api_key from LRR_API_KEY env");
            crate::db::api_key::insert_if_empty(pool, &hash).await?;
        }
        (Some(_), Some(_)) => {
            // env set + table populated: DB wins, env ignored.
            tracing::info!("LRR_API_KEY env set but lrr_api_key table is non-empty; using DB");
        }
        (None, None) => {
            // env unset + table empty: read-only mode.
            tracing::warn!(
                "LRR_API_KEY not set and lrr_api_key table is empty; \
                 server running in read-only mode (secured routes return 401)"
            );
        }
        (None, Some(_)) => {
            // env unset + table populated: normal operation via DB.
        }
    }

    Ok(())
}
