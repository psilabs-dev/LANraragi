//! Filesystem support helpers.

use std::path::{Path, PathBuf};

/// Returns the final on-disk path for an uploaded archive within `content_dir`,
/// preserving the user-supplied filename. Strips any leading directory
/// components so a malicious filename cannot escape the content root.
pub fn resolve_upload_target(content_dir: &Path, filename: &str) -> PathBuf {
    let stripped = Path::new(filename)
        .file_name()
        .map_or_else(|| Path::new(filename), Path::new);
    content_dir.join(stripped)
}

/// Returns the file extension (lowercased, without leading dot) if the
/// filename has one and it is non-empty.
pub fn extension(filename: &str) -> Option<String> {
    Path::new(filename)
        .extension()
        .and_then(|os| os.to_str())
        .map(str::to_ascii_lowercase)
}
