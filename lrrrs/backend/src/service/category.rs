//! Category business logic.

use sqlx::PgPool;

use crate::db;
use crate::db::archive;

/// Wire-shape for a single category, matching the `CategoryMetadataJson` schema.
/// `pinned` is sent as an integer (0/1) per the openapi.yaml `enum: [0, 1]`.
#[derive(serde::Serialize)]
pub struct CategoryDto {
    pub id: String,
    pub name: String,
    pub pinned: u8,
    pub search: String,
    pub archives: Vec<String>,
}

/// Error type for category write operations.
#[derive(Debug)]
pub enum CategoryError {
    NotFound(String),
    IsDynamic(String),
    ArchiveNotFound(String),
    Db(sqlx::Error),
}

impl std::fmt::Display for CategoryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound(id) => write!(f, "{id} doesn't exist in the database!"),
            Self::IsDynamic(id) => write!(
                f,
                "{id} is a favorite search/dynamic category, can't add archives to it."
            ),
            Self::ArchiveNotFound(id) => write!(f, "{id} does not exist in the database."),
            Self::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

impl std::error::Error for CategoryError {}

impl From<CategoryError> for crate::error::PendingApiError {
    fn from(e: CategoryError) -> Self {
        use crate::error::PendingApiError;
        match e {
            // openapi declares 400 only; matches Perl render_api_response behavior
            CategoryError::NotFound(msg) => PendingApiError::bad_request(msg),
            CategoryError::IsDynamic(msg) | CategoryError::ArchiveNotFound(msg) => {
                PendingApiError::bad_request(msg)
            }
            CategoryError::Db(e) => PendingApiError::internal(e.to_string()),
        }
    }
}

fn into_dto(row: db::category::CategoryRow, archives: Vec<String>) -> CategoryDto {
    CategoryDto {
        id: row.catid,
        name: row.name,
        pinned: if row.pinned { 1 } else { 0 },
        search: row.search,
        archives,
    }
}
pub async fn list_all(pool: &PgPool) -> Result<Vec<CategoryDto>, sqlx::Error> {
    let rows = db::category::list_all(pool).await?;
    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let archives = if row.search.is_empty() {
            db::category::list_archives(pool, &row.catid).await?
        } else {
            Vec::new()
        };
        result.push(into_dto(row, archives));
    }
    Ok(result)
}
pub async fn get(pool: &PgPool, catid: &str) -> Result<Option<CategoryDto>, sqlx::Error> {
    let Some(row) = db::category::get(pool, catid).await? else {
        return Ok(None);
    };
    let archives = if row.search.is_empty() {
        db::category::list_archives(pool, catid).await?
    } else {
        Vec::new()
    };
    Ok(Some(into_dto(row, archives)))
}

/// Generates a unique category ID in the form `SET_<epoch_seconds>`.
/// Increments the timestamp until no collision is found.
fn new_catid_base() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("SET_{secs}")
}
pub async fn create(
    pool: &PgPool,
    name: &str,
    search: Option<&str>,
    pinned: bool,
) -> Result<String, sqlx::Error> {
    let mut tx = pool.begin().await?;
    db::lock::lock_category_create(&mut *tx).await?;
    let mut catid = new_catid_base();
    // Resolve collision by incrementing the numeric suffix.
    // pool is used for the read (exists); the advisory lock above serializes concurrent creates.
    loop {
        let exists = db::category::exists(pool, &catid).await?;
        if !exists {
            break;
        }
        // Increment the timestamp suffix by 1.
        if let Some(ts_str) = catid.strip_prefix("SET_") {
            let ts: u64 = ts_str.parse().unwrap_or(0);
            catid = format!("SET_{}", ts + 1);
        } else {
            break;
        }
    }
    db::category::upsert(&mut *tx, &catid, name, search, pinned).await?;
    tx.commit().await?;
    Ok(catid)
}
pub async fn update(
    pool: &PgPool,
    catid: &str,
    name: &str,
    search: Option<&str>,
    pinned: bool,
) -> Result<(), CategoryError> {
    let exists = db::category::get(pool, catid)
        .await
        .map_err(CategoryError::Db)?;
    if exists.is_none() {
        return Err(CategoryError::NotFound(format!(
            "{catid} doesn't exist in the database!"
        )));
    }
    db::category::upsert(pool, catid, name, search, pinned)
        .await
        .map_err(CategoryError::Db)
}
// Perl returns 1 (success) for both existing and missing categories; no 404
// is declared in openapi.yaml for deleteCategory, so this mirrors that behavior.
pub async fn delete(pool: &PgPool, catid: &str) -> Result<(), sqlx::Error> {
    let row = db::category::get(pool, catid).await?;
    if row.is_none() {
        return Ok(());
    }
    let mut tx = pool.begin().await?;
    db::lock::lock_category_write(&mut *tx, catid).await?;
    // Read bookmark_link inside the transaction to avoid a TOCTOU window where a
    // concurrent update_bookmark_link could set the pointer to catid between
    // read and delete, leaving lrr_config.bookmark_link referencing a removed catid.
    let bookmark = db::category::get_bookmark_link(&mut *tx).await?;
    if bookmark.as_deref() == Some(catid) {
        db::category::set_bookmark_link(&mut *tx, None).await?;
    }
    db::category::delete(&mut tx, catid).await?;
    tx.commit().await?;
    Ok(())
}
pub async fn add_to_category(
    pool: &PgPool,
    catid: &str,
    arcid: &str,
) -> Result<(), CategoryError> {
    let cat_row = db::category::get(pool, catid)
        .await
        .map_err(CategoryError::Db)?;
    let Some(cat) = cat_row else {
        return Err(CategoryError::NotFound(format!(
            "{catid} doesn't exist in the database!"
        )));
    };
    if !cat.search.is_empty() {
        return Err(CategoryError::IsDynamic(format!(
            "{catid} is a favorite search/dynamic category, can't add archives to it."
        )));
    }
    let arc_exists = archive::exists(pool, arcid)
        .await
        .map_err(CategoryError::Db)?;
    if !arc_exists {
        return Err(CategoryError::ArchiveNotFound(format!(
            "{arcid} does not exist in the database."
        )));
    }
    let already = db::category::archive_in_category(pool, catid, arcid)
        .await
        .map_err(CategoryError::Db)?;
    if already {
        // Perl returns (1, warning); idempotent success.
        return Ok(());
    }
    let mut tx = pool.begin().await.map_err(CategoryError::Db)?;
    db::lock::lock_category_write(&mut *tx, catid)
        .await
        .map_err(CategoryError::Db)?;
    db::category::add_archive(&mut *tx, catid, arcid)
        .await
        .map_err(CategoryError::Db)?;
    tx.commit().await.map_err(CategoryError::Db)
}
pub async fn remove_from_category(
    pool: &PgPool,
    catid: &str,
    arcid: &str,
) -> Result<(), CategoryError> {
    let cat_row = db::category::get(pool, catid)
        .await
        .map_err(CategoryError::Db)?;
    let Some(cat) = cat_row else {
        return Err(CategoryError::NotFound(format!(
            "{catid} doesn't exist in the database!"
        )));
    };
    if !cat.search.is_empty() {
        return Err(CategoryError::IsDynamic(format!(
            "{catid} is a favorite search, it doesn't contain archives."
        )));
    }
    let mut tx = pool.begin().await.map_err(CategoryError::Db)?;
    db::lock::lock_category_write(&mut *tx, catid)
        .await
        .map_err(CategoryError::Db)?;
    db::category::remove_archive(&mut *tx, catid, arcid)
        .await
        .map_err(CategoryError::Db)?;
    tx.commit().await.map_err(CategoryError::Db)
}

/// Returns the bookmark_link category ID, or empty string if none is set.
pub async fn get_bookmark_link(pool: &PgPool) -> Result<String, sqlx::Error> {
    let val = db::category::get_bookmark_link(pool).await?;
    Ok(val.unwrap_or_default())
}

/// Links the bookmark button to a static category. Returns the validated catid.
pub async fn update_bookmark_link(
    pool: &PgPool,
    catid: &str,
) -> Result<(), BookmarkError> {
    let cat_row = db::category::get(pool, catid)
        .await
        .map_err(BookmarkError::Db)?;
    let Some(cat) = cat_row else {
        return Err(BookmarkError::NotFound);
    };
    if !cat.search.is_empty() {
        return Err(BookmarkError::IsDynamic);
    }
    db::category::set_bookmark_link(pool, Some(catid))
        .await
        .map_err(BookmarkError::Db)
}

/// Removes the bookmark link and returns the previously linked catid (or empty).
pub async fn remove_bookmark_link(pool: &PgPool) -> Result<String, sqlx::Error> {
    let old = db::category::get_bookmark_link(pool).await?;
    db::category::set_bookmark_link(pool, None).await?;
    Ok(old.unwrap_or_default())
}

/// Error type for bookmark update operations.
#[derive(Debug)]
pub enum BookmarkError {
    NotFound,
    IsDynamic,
    Db(sqlx::Error),
}

impl std::fmt::Display for BookmarkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => write!(f, "Category does not exist!"),
            Self::IsDynamic => write!(f, "Cannot link bookmark to a dynamic category."),
            Self::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

impl std::error::Error for BookmarkError {}

impl From<BookmarkError> for crate::error::PendingApiError {
    fn from(e: BookmarkError) -> Self {
        use crate::error::PendingApiError;
        match e {
            BookmarkError::NotFound => PendingApiError::not_found("Category does not exist!"),
            BookmarkError::IsDynamic => {
                PendingApiError::bad_request("Cannot link bookmark to a dynamic category.")
            }
            BookmarkError::Db(e) => PendingApiError::internal(e.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_catid_base_format() {
        let id = new_catid_base();
        assert!(id.starts_with("SET_"), "catid must start with SET_");
        let ts_part = id.strip_prefix("SET_").unwrap();
        let parsed: u64 = ts_part.parse().expect("timestamp portion must be numeric");
        // 1_000_000_000 is Jan 2001; any real timestamp is larger.
        assert!(parsed > 1_000_000_000, "timestamp must be a plausible epoch");
    }

    #[test]
    fn into_dto_static() {
        let row = db::category::CategoryRow {
            catid: "SET_1613080290".into(),
            name: "Test".into(),
            pinned: true,
            search: String::new(),
        };
        let dto = into_dto(row, vec!["abc".into()]);
        assert_eq!(dto.id, "SET_1613080290");
        assert_eq!(dto.pinned, 1);
        assert_eq!(dto.archives.len(), 1);
    }

    #[test]
    fn into_dto_dynamic() {
        let row = db::category::CategoryRow {
            catid: "SET_1613080291".into(),
            name: "Dynamic".into(),
            pinned: false,
            search: "tag:foo".into(),
        };
        let dto = into_dto(row, Vec::new());
        assert_eq!(dto.pinned, 0);
        assert_eq!(dto.search, "tag:foo");
        assert!(dto.archives.is_empty());
    }
}
