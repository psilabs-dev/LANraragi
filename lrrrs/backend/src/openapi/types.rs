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

pub use generated::types::{
    ArchiveMetadataJson, ArchiveMetadataJsonArcid, ArchiveMetadataJsonIsnew, ServerInfo,
};

use serde::Serialize;

/// Response payload of GET /api/shinobu.
#[derive(Serialize)]
pub struct ShinobuStatus {
    pub operation: &'static str,
    pub success: u8,
    pub is_alive: u8,
    pub pid: u32,
}

/// Response payload of POST /api/shinobu/restart and POST /api/shinobu/rescan.
#[derive(Serialize)]
pub struct ShinobuRestart {
    pub operation: &'static str,
    pub success: u8,
    pub new_pid: u32,
}
