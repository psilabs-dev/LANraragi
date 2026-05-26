//! Shinobu (file watcher) theme handlers.

use axum::{Json, extract::State};

use crate::openapi::responses::op_success;
use crate::openapi::types::{ShinobuRestart, ShinobuStatus};
use crate::state::AppState;

// port of LANraragi::Controller::Api::Shinobu::shinobu_status
// commit hash: f7249980
pub async fn shinobu_status(State(state): State<AppState>) -> Json<ShinobuStatus> {
    let (alive, pid) = state.shinobu.status().await;
    Json(ShinobuStatus {
        operation: "shinobu_status",
        success: 1,
        is_alive: u8::from(alive),
        pid,
    })
}

// port of LANraragi::Controller::Api::Shinobu::stop_shinobu
// commit hash: f7249980
pub async fn shinobu_stop(State(state): State<AppState>) -> Json<serde_json::Value> {
    state.shinobu.stop().await;
    op_success("shinobu_stop")
}

// port of LANraragi::Controller::Api::Shinobu::restart_shinobu
// commit hash: f7249980
pub async fn shinobu_restart(State(state): State<AppState>) -> Json<ShinobuRestart> {
    let new_pid = state.shinobu.restart().await;
    Json(ShinobuRestart {
        operation: "shinobu_restart",
        success: 1,
        new_pid,
    })
}

// port of LANraragi::Controller::Api::Shinobu::reset_filemap
// commit hash: f7249980
pub async fn shinobu_rescan(State(state): State<AppState>) -> Json<ShinobuRestart> {
    let new_pid = state.shinobu.rescan().await;
    Json(ShinobuRestart {
        operation: "shinobu_rescan",
        success: 1,
        new_pid,
    })
}
