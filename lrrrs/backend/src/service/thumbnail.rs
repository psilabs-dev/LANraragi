//! Thumbnail generation and serving. Output format: WebP. Supported sources: JPEG, PNG, WebP, GIF.

use std::path::{Path, PathBuf};

// Path layout: `thumb/<first-2-chars>/<arcid>.webp`
pub fn cover_thumb_path(thumb_dir: &Path, arcid: &str) -> PathBuf {
    let sub = &arcid[..2];
    thumb_dir.join(sub).join(format!("{arcid}.webp"))
}

// Path layout: `thumb/<first-2-chars>/<arcid>/<page>.webp`
pub fn page_thumb_path(thumb_dir: &Path, arcid: &str, page: u32) -> PathBuf {
    let sub = &arcid[..2];
    thumb_dir.join(sub).join(arcid).join(format!("{page}.webp"))
}

// Path layout: `thumb/TA/<tankid>.webp`
pub fn tank_thumb_path(thumb_dir: &Path, tankid: &str) -> PathBuf {
    thumb_dir.join("TA").join(format!("{tankid}.webp"))
}

// Path layout: `temp/<arcid>/`
pub fn temp_extract_dir(temp_dir: &Path, arcid: &str) -> PathBuf {
    temp_dir.join(arcid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn cover_thumb_path_layout() {
        let thumb = Path::new("/srv/thumb");
        let arcid = "d1858d5dc36925aa66be072a97817650d39de166";
        let p = cover_thumb_path(thumb, arcid);
        assert_eq!(p, Path::new("/srv/thumb/d1/d1858d5dc36925aa66be072a97817650d39de166.webp"));
    }

    #[test]
    fn page_thumb_path_layout() {
        let thumb = Path::new("/srv/thumb");
        let arcid = "d1858d5dc36925aa66be072a97817650d39de166";
        let p = page_thumb_path(thumb, arcid, 3);
        assert_eq!(p, Path::new("/srv/thumb/d1/d1858d5dc36925aa66be072a97817650d39de166/3.webp"));
    }

    #[test]
    fn temp_extract_dir_layout() {
        let temp = Path::new("/srv/temp");
        let arcid = "d1858d5dc36925aa66be072a97817650d39de166";
        let p = temp_extract_dir(temp, arcid);
        assert_eq!(p, Path::new("/srv/temp/d1858d5dc36925aa66be072a97817650d39de166"));
    }
}
