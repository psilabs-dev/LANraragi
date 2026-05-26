//! Archive-related support helpers.

use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};

use crate::support::cpu::{self, CpuTaskError};

const IMAGE_EXTENSIONS: &[&str] = &["jpg", "jpeg", "png", "webp", "gif"];

#[derive(Debug)]
pub enum ProbeError {
    NotZip,
    EmptyArchive,
    Io(std::io::Error),
    Zip(zip::result::ZipError),
    Worker(CpuTaskError),
}

impl std::fmt::Display for ProbeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotZip => write!(f, "archive is not a valid ZIP"),
            Self::EmptyArchive => write!(f, "archive contains no images"),
            Self::Io(e) => write!(f, "io error reading archive: {e}"),
            Self::Zip(e) => write!(f, "zip parse error: {e}"),
            Self::Worker(e) => write!(f, "cpu worker error: {e}"),
        }
    }
}

impl std::error::Error for ProbeError {}

impl From<ProbeError> for crate::error::PendingApiError {
    fn from(e: ProbeError) -> Self {
        use crate::error::PendingApiError;
        match e {
            ProbeError::NotZip
            | ProbeError::EmptyArchive
            | ProbeError::Zip(_)
            | ProbeError::Worker(_) => PendingApiError::bad_request(e.to_string()),
            ProbeError::Io(io) => PendingApiError::internal(io.to_string()),
        }
    }
}

#[derive(Debug)]
pub struct ProbeResult {
    pub pagecount: u32,
}

/// Open the archive at `path` on the Rayon pool, count image entries, and
/// return the metadata. Errors panic-safely via `cpu::run`.
pub async fn probe(pool: &rayon::ThreadPool, path: PathBuf) -> Result<ProbeResult, ProbeError> {
    cpu::run(pool, move || probe_blocking(&path))
        .await
        .map_err(ProbeError::Worker)?
}

fn probe_blocking(path: &Path) -> Result<ProbeResult, ProbeError> {
    let file = File::open(path).map_err(ProbeError::Io)?;
    let reader = BufReader::new(file);
    let mut archive = zip::ZipArchive::new(reader).map_err(|e| match e {
        zip::result::ZipError::InvalidArchive(_) => ProbeError::NotZip,
        other => ProbeError::Zip(other),
    })?;

    let mut pagecount: u32 = 0;
    for i in 0..archive.len() {
        let entry = archive.by_index(i).map_err(ProbeError::Zip)?;
        if entry.is_dir() {
            continue;
        }
        if has_image_extension(entry.name()) {
            pagecount += 1;
        }
    }

    if pagecount == 0 {
        return Err(ProbeError::EmptyArchive);
    }

    Ok(ProbeResult { pagecount })
}

fn has_image_extension(name: &str) -> bool {
    let lower = name.rsplit('.').next().map(str::to_ascii_lowercase);
    matches!(lower, Some(ext) if IMAGE_EXTENSIONS.contains(&ext.as_str()))
}
