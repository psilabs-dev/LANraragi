//! Tankoubon business logic.

use std::path::Path;

use serde_json::{Value, json};
use sqlx::PgPool;

use crate::db;
use crate::openapi::types::ArchiveMetadataJson;

#[derive(Debug)]
pub enum TankError {
    NotFound(String),
    ArchiveNotFound(String),
    InvalidProgress,
    Db(sqlx::Error),
}

impl std::fmt::Display for TankError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound(id) => write!(f, "The given tankoubon does not exist: {id}"),
            Self::ArchiveNotFound(id) => write!(f, "{id} does not exist in the database."),
            Self::InvalidProgress => write!(f, "Invalid progress value."),
            Self::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

impl std::error::Error for TankError {}

impl From<TankError> for crate::error::PendingApiError {
    fn from(e: TankError) -> Self {
        use crate::error::PendingApiError;
        match e {
            TankError::NotFound(_)
            | TankError::ArchiveNotFound(_)
            | TankError::InvalidProgress => PendingApiError::bad_request(e.to_string()),
            TankError::Db(db) => PendingApiError::internal(db.to_string()),
        }
    }
}

pub struct TankListItem {
    pub id: String,
    pub name: String,
    pub summary: String,
    pub tags: String,
    pub archives: Vec<String>,
}

/// Returns `(total, filtered, page_items)`.
pub async fn list(
    pool: &PgPool,
    page: Option<i64>,
    pagesize: i64,
) -> Result<(i64, i64, Vec<TankListItem>), TankError> {
    let rows = db::tankoubons::list_all(pool).await.map_err(TankError::Db)?;
    // usize to i64 cannot fail on any 64-bit platform (same range).
    let total = i64::try_from(rows.len())
        .expect("tankoubon count overflows i64: list exceeds i64::MAX entries");

    let all_items: Vec<TankListItem> = rows
        .into_iter()
        .map(|r| TankListItem {
            id: r.tankid,
            name: r.name,
            summary: r.summary.unwrap_or_default(),
            tags: r.tags.unwrap_or_default(),
            archives: Vec::new(), // archives fetched below
        })
        .collect();

    // Fetch archive lists for the page slice only (avoids N+1 on full corpus).
    let page_val = page.unwrap_or(0);
    let (start, end) = if page_val < 0 {
        (0, all_items.len())
    } else {
        let offset = page_val
            .checked_mul(pagesize)
            .and_then(|v| usize::try_from(v).ok())
            .ok_or_else(|| TankError::InvalidProgress)?;
        let limit = usize::try_from(pagesize).unwrap_or(all_items.len());
        let end = offset.saturating_add(limit).min(all_items.len());
        (offset, end)
    };

    if start >= all_items.len() {
        return Ok((total, 0, Vec::new()));
    }

    let mut page_items = all_items;
    page_items = page_items.into_iter().skip(start).take(end - start).collect();

    // Enrich each tank with its archive list.
    for item in page_items.iter_mut() {
        item.archives = db::tankoubons::get_archives(pool, &item.id)
            .await
            .map_err(TankError::Db)?;
    }

    // Mirror Perl PgTankoubon: return $total as the filtered count on all branches.
    Ok((total, total, page_items))
}

pub struct TankDetail {
    pub id: String,
    pub name: String,
    pub summary: String,
    pub tags: String,
    pub archives: Vec<String>,
    pub full_data: Option<Vec<ArchiveMetadataJson>>,
    pub total: i64,
    pub filtered: i64,
}
pub async fn get(
    pool: &PgPool,
    tankid: &str,
    include_full_data: bool,
    page: Option<i64>,
    pagesize: i64,
) -> Result<TankDetail, TankError> {
    let row = db::tankoubons::get(pool, tankid)
        .await
        .map_err(TankError::Db)?
        .ok_or_else(|| TankError::NotFound(tankid.to_string()))?;

    let total = db::tankoubons::count_archives(pool, tankid)
        .await
        .map_err(TankError::Db)?;

    let page_val = page.unwrap_or(0);
    let archives = if page_val < 0 {
        db::tankoubons::get_archives(pool, tankid)
            .await
            .map_err(TankError::Db)?
    } else {
        let offset = page_val
            .checked_mul(pagesize)
            .ok_or(TankError::InvalidProgress)?;
        db::tankoubons::get_archives_page(pool, tankid, pagesize, offset)
            .await
            .map_err(TankError::Db)?
    };

    // usize to i64 cannot fail on any 64-bit platform (same range).
    let filtered = i64::try_from(archives.len())
        .expect("archive page count overflows i64: page slice exceeds i64::MAX entries");

    let full_data = if include_full_data {
        Some(fetch_full_data(pool, &archives).await?)
    } else {
        None
    };

    Ok(TankDetail {
        id: tankid.to_string(),
        name: row.name,
        summary: row.summary.unwrap_or_default(),
        tags: row.tags.unwrap_or_default(),
        archives,
        full_data,
        total,
        filtered,
    })
}

/// Batch-fetch archive metadata for a list of arcids, preserving order.
async fn fetch_full_data(
    pool: &PgPool,
    arcids: &[String],
) -> Result<Vec<ArchiveMetadataJson>, TankError> {
    if arcids.is_empty() {
        return Ok(Vec::new());
    }
    // Fetch all archive rows in a single query via ANY($1).
    let rows = db::archive::list_by_arcids(pool, arcids)
        .await
        .map_err(TankError::Db)?;

    // Index by arcid for O(1) lookup.
    let mut by_id: std::collections::HashMap<String, db::archive::ArchiveRow> =
        rows.into_iter().map(|r| (r.arcid.clone(), r)).collect();

    // Re-order according to the tankoubon sequence.
    let mut out = Vec::with_capacity(arcids.len());
    for arcid in arcids {
        if let Some(r) = by_id.remove(arcid) {
            out.push(super::archive::row_into_dto(r, Vec::new()));
        }
    }
    Ok(out)
}

// Epoch-based ID so concurrent creates naturally space out without a counter.
fn generate_tankid() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch is not supported")
        .as_secs();
    format!("TANK_{epoch:010}")
}
pub async fn create(pool: &PgPool, name: &str, tankid: Option<&str>) -> Result<String, TankError> {
    match tankid {
        Some(id) if !id.is_empty() => {
            // Update existing tank's name.
            let exists = db::tankoubons::exists(pool, id)
                .await
                .map_err(TankError::Db)?;
            if exists {
                db::tankoubons::update_name(pool, id, name)
                    .await
                    .map_err(TankError::Db)?;
            } else {
                db::tankoubons::insert(pool, id, name)
                    .await
                    .map_err(TankError::Db)?;
            }
            Ok(id.to_string())
        }
        _ => {
            // Generate a new unique ID.
            let mut new_id = generate_tankid();
            while db::tankoubons::exists(pool, &new_id)
                .await
                .map_err(TankError::Db)?
            {
                // Advance by 1 second until we find a free slot.
                // new_id is always produced by generate_tankid() which emits
                // "TANK_<10-digit-epoch>"; parse failure indicates corruption.
                let epoch: u64 = new_id
                    .trim_start_matches("TANK_")
                    .parse()
                    .expect("generate_tankid produced a non-numeric suffix; this is a bug");
                new_id = format!("TANK_{:010}", epoch + 1);
            }
            db::tankoubons::insert(pool, &new_id, name)
                .await
                .map_err(TankError::Db)?;
            Ok(new_id)
        }
    }
}
pub async fn delete(pool: &PgPool, tankid: &str) -> Result<(), TankError> {
    let exists = db::tankoubons::exists(pool, tankid)
        .await
        .map_err(TankError::Db)?;
    if !exists {
        return Err(TankError::NotFound(tankid.to_string()));
    }
    let mut tx = pool.begin().await.map_err(TankError::Db)?;
    db::tankoubons::delete(&mut tx, tankid)
        .await
        .map_err(TankError::Db)?;
    tx.commit().await.map_err(TankError::Db)
}

/// Payload from the `updateTankoubon` request body.
pub struct UpdateInput {
    pub name: Option<String>,
    pub summary: Option<String>,
    pub tags: Option<String>,
    pub archives: Option<Vec<String>>,
}
pub async fn update(pool: &PgPool, tankid: &str, input: UpdateInput) -> Result<String, TankError> {
    let exists = db::tankoubons::exists(pool, tankid)
        .await
        .map_err(TankError::Db)?;
    if !exists {
        return Err(TankError::NotFound(tankid.to_string()));
    }

    let has_meta = input.name.is_some() || input.summary.is_some() || input.tags.is_some();
    let has_archives = input.archives.is_some();

    if !has_meta && !has_archives {
        // Nothing to do; return current name.
        let row = db::tankoubons::get(pool, tankid)
            .await
            .map_err(TankError::Db)?
            .ok_or_else(|| TankError::NotFound(tankid.to_string()))?;
        return Ok(row.name);
    }

    // Single transaction: validate archive IDs first (inside the tx so the
    // existence read is consistent), then apply metadata + archive changes.
    // If any arcid does not exist the transaction rolls back, leaving
    // metadata unchanged.
    let mut tx = pool.begin().await.map_err(TankError::Db)?;

    if let Some(arcids) = &input.archives {
        for arcid in arcids {
            let ok = db::archive::exists(&mut *tx, arcid)
                .await
                .map_err(TankError::Db)?;
            if !ok {
                return Err(TankError::ArchiveNotFound(arcid.clone()));
            }
        }
    }

    if has_meta {
        db::tankoubons::update_metadata(
            &mut tx,
            tankid,
            input.name.as_deref(),
            input.summary.as_deref(),
            input.tags.as_deref(),
        )
        .await
        .map_err(TankError::Db)?;
    }

    if let Some(arcids) = input.archives {
        db::tankoubons::replace_archives(&mut tx, tankid, &arcids)
            .await
            .map_err(TankError::Db)?;
    }

    tx.commit().await.map_err(TankError::Db)?;

    // Return the updated name for the success message.
    let row = db::tankoubons::get(pool, tankid)
        .await
        .map_err(TankError::Db)?
        .ok_or_else(|| TankError::NotFound(tankid.to_string()))?;
    Ok(row.name)
}
pub async fn add_archive(pool: &PgPool, tankid: &str, arcid: &str) -> Result<(), TankError> {
    let tank_exists = db::tankoubons::exists(pool, tankid)
        .await
        .map_err(TankError::Db)?;
    if !tank_exists {
        return Err(TankError::NotFound(tankid.to_string()));
    }

    let arc_exists = db::archive::exists(pool, arcid)
        .await
        .map_err(TankError::Db)?;
    if !arc_exists {
        return Err(TankError::ArchiveNotFound(arcid.to_string()));
    }

    let already = db::tankoubons::mapping_exists(pool, tankid, arcid)
        .await
        .map_err(TankError::Db)?;
    if already {
        // Idempotent; mirrors Perl which returns success=1 with a warning.
        return Ok(());
    }

    db::tankoubons::add_archive(pool, tankid, arcid)
        .await
        .map_err(TankError::Db)?;
    Ok(())
}
pub async fn remove_archive(pool: &PgPool, tankid: &str, arcid: &str) -> Result<(), TankError> {
    let tank_exists = db::tankoubons::exists(pool, tankid)
        .await
        .map_err(TankError::Db)?;
    if !tank_exists {
        return Err(TankError::NotFound(tankid.to_string()));
    }

    let arc_exists = db::archive::exists(pool, arcid)
        .await
        .map_err(TankError::Db)?;
    if !arc_exists {
        return Err(TankError::ArchiveNotFound(arcid.to_string()));
    }

    let is_member = db::tankoubons::mapping_exists(pool, tankid, arcid)
        .await
        .map_err(TankError::Db)?;
    if !is_member {
        // Idempotent; mirrors Perl which returns success=1 with a warning.
        return Ok(());
    }

    let mut tx = pool.begin().await.map_err(TankError::Db)?;
    db::tankoubons::remove_archive(&mut tx, tankid, arcid)
        .await
        .map_err(TankError::Db)?;
    tx.commit().await.map_err(TankError::Db)
}

pub struct ProgressResult {
    pub page: i32,
    pub lastreadtime: i64,
}
pub async fn update_progress(
    pool: &PgPool,
    tankid: &str,
    page: i32,
) -> Result<ProgressResult, TankError> {
    if page < 1 {
        return Err(TankError::InvalidProgress);
    }

    let exists = db::tankoubons::exists(pool, tankid)
        .await
        .map_err(TankError::Db)?;
    if !exists {
        return Err(TankError::NotFound(tankid.to_string()));
    }

    let now = i64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before Unix epoch is not supported")
            .as_secs(),
    )
    .expect("Unix timestamp overflows i64");

    db::tankoubons::update_progress(pool, tankid, page, now)
        .await
        .map_err(TankError::Db)?;

    Ok(ProgressResult {
        page,
        lastreadtime: now,
    })
}

/// Check whether a tankoubon exists by id.
pub async fn tank_exists(pool: &PgPool, tankid: &str) -> Result<bool, sqlx::Error> {
    db::tankoubons::exists(pool, tankid).await
}

/// Total pagecount across all archives in a tankoubon.
pub async fn total_pagecount(pool: &PgPool, tankid: &str) -> Result<i64, sqlx::Error> {
    db::tankoubons::get_total_pagecount(pool, tankid).await
}

/// Enqueue a tankoubon thumbnail generation job and return the job id.
pub async fn enqueue_thumbnail_job(pool: &PgPool, tankid: &str) -> Result<i64, TankError> {
    db::jobs::insert(pool, "tank_thumbnail", &json!([tankid]), 0)
        .await
        .map_err(TankError::Db)
}

/// Enqueue a tankoubon thumbnail generation job for a specific page and return the job id.
pub async fn enqueue_thumbnail_job_for_page(
    pool: &PgPool,
    tankid: &str,
    page: i64,
) -> Result<i64, TankError> {
    db::jobs::insert(pool, "tank_thumbnail", &json!([tankid, page]), 0)
        .await
        .map_err(TankError::Db)
}

/// Serve or enqueue the tankoubon cover thumbnail.
/// - File exists: return 200 bytes.
/// - File absent + `no_fallback=true`: enqueue job, return job id (202).
/// - File absent + `no_fallback=false`: return 1×1 placeholder.
pub async fn get_thumbnail(
    pool: &PgPool,
    thumb_dir: &Path,
    tankid: &str,
    no_fallback: bool,
) -> Result<super::archive::ThumbnailResult, TankError> {
    let thumb_path = crate::service::thumbnail::tank_thumb_path(thumb_dir, tankid);

    if tokio::fs::try_exists(&thumb_path)
        .await
        .map_err(|e| TankError::Db(sqlx::Error::Io(e)))?
    {
        let bytes = tokio::fs::read(&thumb_path)
            .await
            .map_err(|e| TankError::Db(sqlx::Error::Io(e)))?;
        return Ok(super::archive::ThumbnailResult::Bytes(bytes));
    }

    if no_fallback {
        let job_id = enqueue_thumbnail_job(pool, tankid).await?;
        return Ok(super::archive::ThumbnailResult::Queued(job_id));
    }

    Ok(super::archive::ThumbnailResult::Bytes(
        super::archive::placeholder_webp(),
    ))
}

/// Convert the internal list representation to the JSON wire format used by
/// `getTankoubonList` (OperationResponse-style envelope is handled by the
/// controller; this returns the `result` array element shape).
pub fn list_item_to_json(item: &TankListItem) -> Value {
    json!({
        "id": item.id,
        "name": item.name,
        "summary": item.summary,
        "tags": item.tags,
        "archives": item.archives,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// R3-01 regression test: update with valid metadata + one invalid arcid must
    /// return Err and leave the persisted metadata UNCHANGED.
    ///
    /// ignored: requires postgres — run with DATABASE_URL pointing at a live
    /// Postgres instance and remove #[ignore].
    #[ignore]
    #[tokio::test]
    async fn update_with_invalid_arcid_rolls_back_metadata() {
        // Connect to a live Postgres (requires DATABASE_URL env var).
        let database_url = std::env::var("DATABASE_URL")
            .expect("DATABASE_URL must be set to run this test");
        let pool = sqlx::PgPool::connect(&database_url)
            .await
            .expect("failed to connect to Postgres");

        // Insert a tank and a known-good archive for the pre-update state.
        let tankid = format!("TANK_{:010}", 9_000_000_001u64);
        sqlx::query("DELETE FROM lrr_tank WHERE tankid = $1")
            .bind(&tankid)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO lrr_tank (tankid, name, summary, tags) VALUES ($1, $2, $3, $4)",
        )
        .bind(&tankid)
        .bind("OriginalName")
        .bind("OriginalSummary")
        .bind("OriginalTags")
        .execute(&pool)
        .await
        .unwrap();

        // Call update with new metadata AND one nonexistent arcid.
        let result = update(
            &pool,
            &tankid,
            UpdateInput {
                name:     Some("NewName".into()),
                summary:  Some("NewSummary".into()),
                tags:     Some("NewTags".into()),
                archives: Some(vec!["nonexistent_arcid_000000000000000000000000".into()]),
            },
        )
        .await;

        // The call must return an error (ArchiveNotFound).
        assert!(
            result.is_err(),
            "expected Err(ArchiveNotFound) but got Ok"
        );
        matches!(result.unwrap_err(), TankError::ArchiveNotFound(_));

        // The metadata must be UNCHANGED: name/summary/tags must still hold the
        // original values, proving no partial commit occurred.
        let row = db::tankoubons::get(&pool, &tankid)
            .await
            .expect("db::tankoubons::get failed")
            .expect("tank row disappeared");
        assert_eq!(row.name, "OriginalName", "name was mutated despite error");
        assert_eq!(
            row.summary.as_deref(),
            Some("OriginalSummary"),
            "summary was mutated despite error"
        );
        assert_eq!(
            row.tags.as_deref(),
            Some("OriginalTags"),
            "tags were mutated despite error"
        );

        // Cleanup.
        sqlx::query("DELETE FROM lrr_tank WHERE tankid = $1")
            .bind(&tankid)
            .execute(&pool)
            .await
            .unwrap();
    }

    #[test]
    fn generate_tankid_format() {
        let id = generate_tankid();
        assert!(id.starts_with("TANK_"), "tankid must start with TANK_");
        assert_eq!(id.len(), 15, "tankid must be 15 chars: TANK_ + 10 digits");
        let digits = &id["TANK_".len()..];
        assert!(digits.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn archive_row_dto_whitespace_title() {
        // A title that is only whitespace should fall back to filename.
        let row = crate::db::archive::ArchiveRow {
            arcid: "a".repeat(40),
            filename: "test.cbz".into(),
            title: "   ".into(),
            summary: None,
            isnew: false,
            progress: 0,
            pagecount: 0,
            lastreadtime: 0,
            arcsize: None,
            extension: None,
            tags: String::new(),
        };
        let dto = crate::service::archive::row_into_dto(row, Vec::new());
        assert_eq!(dto.title, "test.cbz");
    }

    #[test]
    fn list_item_to_json_shape() {
        let item = TankListItem {
            id: "TANK_1234567890".into(),
            name: "Test Tank".into(),
            summary: "A summary".into(),
            tags: "tag:a".into(),
            archives: vec!["a".repeat(40)],
        };
        let v = list_item_to_json(&item);
        assert_eq!(v["id"], "TANK_1234567890");
        assert_eq!(v["name"], "Test Tank");
        assert_eq!(v["archives"][0], "a".repeat(40).as_str());
    }
}
