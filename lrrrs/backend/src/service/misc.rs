//! Misc business logic (server info, etc.).

use sqlx::PgPool;

use crate::db;
use crate::openapi::types::ServerInfo;

// port of LANraragi::Controller::Api::Other::serve_serverinfo
// commit hash: 61de905b
pub async fn build_server_info(pool: &PgPool) -> Result<ServerInfo, sqlx::Error> {
    let total_archives = db::archive::count(pool).await?;
    Ok(ServerInfo {
        name: "LANraragi".into(),
        motd: String::new(),
        version: env!("CARGO_PKG_VERSION").into(),
        version_name: "LRRRS".into(),
        version_desc: "Rust rewrite of LANraragi".into(),
        has_password: false,
        debug_mode: false,
        nofun_mode: false,
        archives_per_page: 100,
        server_resizes_images: false,
        server_tracks_progress: true,
        authenticated_progress: false,
        total_pages_read: 0,
        total_archives,
        cache_last_cleared: 0,
        excluded_namespaces: vec![],
    })
}
