//! Stamps business logic.

use sqlx::PgPool;

use crate::db;
use crate::error::PendingApiError;

/// Stamp DTO.
#[derive(Debug, serde::Serialize)]
pub struct StampDto {
    pub id:       String,
    pub position: String,
    pub content:  String,
}

#[derive(Debug)]
pub enum StampError {
    NotFound,
    ArchiveNotFound,
    PageOutOfRange(i32),
    Db(sqlx::Error),
}

impl std::fmt::Display for StampError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => write!(f, "The given stamp does not exist."),
            Self::ArchiveNotFound => write!(f, "Archive does not exist in the database."),
            Self::PageOutOfRange(page) => write!(f, "Page {page} out of range."),
            Self::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

impl std::error::Error for StampError {}

impl From<StampError> for PendingApiError {
    fn from(e: StampError) -> Self {
        let msg = e.to_string();
        match e {
            // openapi declares 400 only; matches Perl render_api_response behavior
            StampError::NotFound | StampError::ArchiveNotFound => {
                PendingApiError::bad_request(msg)
            }
            StampError::PageOutOfRange(_) => PendingApiError::bad_request(msg),
            StampError::Db(_) => PendingApiError::internal(msg),
        }
    }
}

/// Returns the stamp identified by `stampid`.
pub async fn get_stamp(pool: &PgPool, stampid: &str) -> Result<StampDto, StampError> {
    let row = db::stamps::get(pool, stampid)
        .await
        .map_err(StampError::Db)?;
    match row {
        Some(r) => Ok(StampDto {
            id:       r.stampid,
            position: r.position,
            content:  r.content,
        }),
        None => Err(StampError::NotFound),
    }
}

/// Returns all stamps on `page` of `arcid`.
pub async fn stamps_by_page(
    pool: &PgPool,
    arcid: &str,
    page: i32,
) -> Result<Vec<StampDto>, StampError> {
    let exists = db::archive::exists(pool, arcid)
        .await
        .map_err(StampError::Db)?;
    if !exists {
        return Err(StampError::ArchiveNotFound);
    }

    let rows = db::stamps::list_by_page(pool, arcid, page)
        .await
        .map_err(StampError::Db)?;
    Ok(rows
        .into_iter()
        .map(|r| StampDto {
            id:       r.stampid,
            position: r.position,
            content:  r.content,
        })
        .collect())
}

/// Returns the distinct page numbers (as strings) that contain at least one
/// stamp in `arcid`.
pub async fn stamped_pages(pool: &PgPool, arcid: &str) -> Result<Vec<String>, StampError> {
    let exists = db::archive::exists(pool, arcid)
        .await
        .map_err(StampError::Db)?;
    if !exists {
        return Err(StampError::ArchiveNotFound);
    }

    db::stamps::list_stamped_pages(pool, arcid)
        .await
        .map_err(StampError::Db)
}

/// Creates a new stamp on the given page of `arcid`.
///
/// The stamp ID is generated as `"{arcid}:{page}:{now_ms}:{rand_hex4}"` to be
/// globally unique, satisfying the `/stamps/{id}` route contract in `openapi.yaml`.
///
/// Pipe characters are stripped from `position` and `content` because the
/// Perl model used `|` as an in-band separator; stripping preserves
/// round-trip semantics for any client that previously stored clean strings.
pub async fn add_stamp(
    pool: &PgPool,
    arcid: &str,
    page: i32,
    content: &str,
    position: &str,
) -> Result<String, StampError> {
    let exists = db::archive::exists(pool, arcid)
        .await
        .map_err(StampError::Db)?;
    if !exists {
        return Err(StampError::ArchiveNotFound);
    }

    // Validate page is within [1, pagecount].
    let pagecount = db::archive::get_pagecount(pool, arcid)
        .await
        .map_err(StampError::Db)?
        .unwrap_or(0);
    if page < 1 || page > pagecount {
        return Err(StampError::PageOutOfRange(page));
    }

    let content = strip_pipe(content);
    let position = strip_pipe(position);

    let stampid = format!("{arcid}:{page}:{}:{}", now_millis(), random_hex4());

    let mut tx = pool.begin().await.map_err(StampError::Db)?;
    // Archive-granularity lock: creating a stamp mutates the archive's stamp set,
    // not a pre-existing stampid (matches Perl add_stamp). update/delete lock by stampid.
    db::lock::lock_archive_write(&mut *tx, arcid)
        .await
        .map_err(StampError::Db)?;
    db::stamps::insert(&mut *tx, &stampid, arcid, page, &position, &content)
        .await
        .map_err(StampError::Db)?;
    tx.commit().await.map_err(StampError::Db)?;

    Ok(stampid)
}

/// Updates the `position` and/or `content` of an existing stamp.
/// Fields supplied as `None` are preserved from the current row.
pub async fn update_stamp(
    pool: &PgPool,
    stampid: &str,
    new_position: Option<&str>,
    new_content: Option<&str>,
) -> Result<(), StampError> {
    let mut tx = pool.begin().await.map_err(StampError::Db)?;
    db::lock::lock_stamp_write(&mut *tx, stampid)
        .await
        .map_err(StampError::Db)?;
    let current = db::stamps::get(&mut *tx, stampid)
        .await
        .map_err(StampError::Db)?
        .ok_or(StampError::NotFound)?;

    // Treat an empty string as "not supplied" (Perl-falsy), so a blank field
    // does not overwrite the stored position/content.
    let position = new_position
        .filter(|s| !s.is_empty())
        .map(strip_pipe)
        .unwrap_or(current.position);
    let content = new_content
        .filter(|s| !s.is_empty())
        .map(strip_pipe)
        .unwrap_or(current.content);

    let updated = db::stamps::update(&mut *tx, stampid, &position, &content)
        .await
        .map_err(StampError::Db)?;

    if !updated {
        return Err(StampError::NotFound);
    }
    tx.commit().await.map_err(StampError::Db)
}

/// Removes a stamp.  Returns `StampError::NotFound` if the stamp does not
/// exist.
pub async fn delete_stamp(pool: &PgPool, stampid: &str) -> Result<(), StampError> {
    let mut tx = pool.begin().await.map_err(StampError::Db)?;
    db::lock::lock_stamp_write(&mut *tx, stampid)
        .await
        .map_err(StampError::Db)?;
    let deleted = db::stamps::delete(&mut *tx, stampid)
        .await
        .map_err(StampError::Db)?;
    if !deleted {
        return Err(StampError::NotFound);
    }
    tx.commit().await.map_err(StampError::Db)
}

// Perl uses `|` as an in-band separator; pipes in position/content would corrupt stored values.
fn strip_pipe(s: &str) -> String {
    s.replace('|', " ")
}

/// Current wall-clock time in milliseconds since the Unix epoch.
fn now_millis() -> u128 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// 4 random bytes rendered as lowercase hex (8 chars).
// Appended to stampid to make same-millisecond concurrent inserts astronomically unlikely to collide.
fn random_hex4() -> String {
    use rand::Rng;
    let bytes: [u8; 4] = rand::thread_rng().r#gen();
    hex::encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::strip_pipe;

    #[test]
    fn strip_pipe_replaces_pipes_with_space() {
        assert_eq!(strip_pipe("a|b|c"), "a b c");
        assert_eq!(strip_pipe("no pipes"), "no pipes");
        assert_eq!(strip_pipe("|leading"), " leading");
        assert_eq!(strip_pipe("trailing|"), "trailing ");
        assert_eq!(strip_pipe(""), "");
    }
}
