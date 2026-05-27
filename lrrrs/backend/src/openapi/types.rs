//! OpenAPI-derived shared schema types.

mod generated {
    #![allow(
        clippy::all,
        clippy::pedantic,
        dead_code,
        missing_docs,
        unused_qualifications
    )]
    include!(concat!(env!("OUT_DIR"), "/openapi_types.rs"));
}

// ArchiveMetadataJsonIsnew serializes the `isnew` field as "true"/"false" strings,
// not JSON booleans. This is a known wire-format quirk documented in openapi.yaml.
pub use generated::types::{
    ArchiveMetadataJson, ArchiveMetadataJsonArcid, ArchiveMetadataJsonIsnew, ServerInfo,
};

use serde::Serialize;

/// Response payload for operationId `shinobuStatus` (`GET /api/shinobu`).
#[derive(Serialize)]
pub struct ShinobuStatus {
    pub operation: &'static str,
    pub success: u8,
    pub is_alive: u8,
    pub pid: u32,
}

/// Response payload for operationId `shinobuRestart` (`POST /api/shinobu/restart`)
/// and operationId `shinobuRescan` (`POST /api/shinobu/rescan`).
#[derive(Serialize)]
pub struct ShinobuRestart {
    pub operation: &'static str,
    pub success: u8,
    pub new_pid: u32,
}
