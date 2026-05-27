//! Backup and restore business logic.

use serde_json::{Value as JsonValue, json};
use sqlx::PgPool;
use tracing::{error, info, warn};

use crate::db;

#[derive(Debug)]
pub enum BackupError {
    Db(sqlx::Error),
}

impl std::fmt::Display for BackupError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

impl std::error::Error for BackupError {}

impl From<BackupError> for crate::error::PendingApiError {
    fn from(e: BackupError) -> Self {
        crate::error::PendingApiError::internal(e.to_string())
    }
}

/// Builds the complete backup as a JSON value.
///
/// Shape:
/// ```json
/// { "archives": [...], "categories": [...], "tankoubons": [...] }
/// ```
pub async fn build_backup_json(pool: &PgPool) -> Result<JsonValue, BackupError> {
    // Categories
    let cat_rows = db::backup::list_categories(pool)
        .await
        .map_err(BackupError::Db)?;
    let mut categories = Vec::with_capacity(cat_rows.len());
    for cat in &cat_rows {
        let arc_rows = db::backup::list_category_archives(pool, &cat.catid)
            .await
            .map_err(BackupError::Db)?;
        let archives: Vec<JsonValue> = arc_rows
            .iter()
            .map(|r| JsonValue::String(r.arcid.clone()))
            .collect();
        categories.push(json!({
            "catid":    cat.catid,
            "name":     cat.name,
            "search":   cat.search,
            "archives": archives,
        }));
    }

    // Tankoubons
    let tank_rows = db::backup::list_tankoubons(pool)
        .await
        .map_err(BackupError::Db)?;
    let mut tankoubons = Vec::with_capacity(tank_rows.len());
    for tank in &tank_rows {
        let arc_rows = db::backup::list_tankoubon_archives(pool, &tank.tankid)
            .await
            .map_err(BackupError::Db)?;
        let archives: Vec<JsonValue> = arc_rows
            .iter()
            .map(|r| JsonValue::String(r.arcid.clone()))
            .collect();
        tankoubons.push(json!({
            "tankid":   tank.tankid,
            "name":     tank.name,
            "archives": archives,
        }));
    }

    // Archives
    let arc_rows = db::backup::list_archives_for_backup(pool)
        .await
        .map_err(BackupError::Db)?;
    let mut archives = Vec::with_capacity(arc_rows.len());
    for arc in &arc_rows {
        archives.push(json!({
            "arcid":     arc.arcid,
            "title":     arc.title,
            "tags":      arc.tags,
            "summary":   arc.summary,
            "thumbhash": arc.thumbhash.as_deref().unwrap_or(""),
            "filename":  arc.filename,
        }));
    }

    Ok(json!({
        "archives":   archives,
        "categories": categories,
        "tankoubons": tankoubons,
    }))
}

/// Restores metadata from a backup JSON value into the database.
///
/// The entire operation runs inside a single transaction: the pre-clean
/// (drop all categories/tankoubons) and the restore of categories,
/// tankoubons, and archive metadata are all committed atomically. Any
/// error rolls back both the clean and the partial restore, so re-queuing
/// the task is always safe.
///
/// Only updates archives that already exist (matching by arcid).
pub async fn restore_from_json(pool: &PgPool, backup: &JsonValue) -> Result<(), BackupError> {
    info!("Received a JSON backup to restore.");

    // Single outer transaction: pre-clean and full restore are atomic.
    let mut tx = pool.begin().await.map_err(BackupError::Db)?;

    db::backup::clean_categories_and_tanks(&mut *tx)
        .await
        .map_err(BackupError::Db)?;

    // Restore categories
    if let Some(categories) = backup["categories"].as_array() {
        for cat in categories {
            let catid = cat["catid"].as_str().unwrap_or_default();
            if catid.is_empty() {
                warn!("Skipping malformed category entry: missing or empty catid");
                continue;
            }
            let name = cat["name"].as_str().unwrap_or_default();
            let search = cat["search"].as_str().unwrap_or_default();
            info!("Restoring Category {catid}...");

            db::backup::upsert_category(&mut *tx, catid, name, search)
                .await
                .map_err(|e| {
                    error!("Failed to upsert category {catid}: {e}");
                    BackupError::Db(e)
                })?;

            if let Some(archives) = cat["archives"].as_array() {
                for arc_val in archives {
                    let arcid = arc_val.as_str().unwrap_or_default();
                    match db::archive::exists(&mut *tx, arcid).await {
                        Ok(true) => {}
                        Ok(false) => {
                            warn!("Skipping category link: archive {arcid} not in database");
                            continue;
                        }
                        Err(e) => {
                            warn!("Could not check existence of {arcid}: {e}");
                            continue;
                        }
                    }
                    if let Err(e) =
                        db::backup::insert_category_archive(&mut *tx, catid, arcid).await
                    {
                        warn!("Failed to link archive {arcid} to category {catid}: {e}");
                    }
                }
            }
        }
    }

    // Restore tankoubons
    if let Some(tankoubons) = backup["tankoubons"].as_array() {
        for tank in tankoubons {
            let tankid = tank["tankid"].as_str().unwrap_or_default();
            if tankid.is_empty() {
                warn!("Skipping malformed tankoubon entry: missing or empty tankid");
                continue;
            }
            let name = tank["name"].as_str().unwrap_or_default();
            info!("Restoring Tankoubon {tankid}...");

            db::backup::upsert_tankoubon(&mut *tx, tankid, name)
                .await
                .map_err(|e| {
                    error!("Failed to upsert tankoubon {tankid}: {e}");
                    BackupError::Db(e)
                })?;

            if let Some(archives) = tank["archives"].as_array() {
                for (pos, arc_val) in archives.iter().enumerate() {
                    let arcid = arc_val.as_str().unwrap_or_default();
                    let position = match i32::try_from(pos + 1) {
                        Ok(p) => p,
                        Err(_) => {
                            error!("Tankoubon archive position overflows i32 at index {pos}; aborting restore");
                            return Err(BackupError::Db(sqlx::Error::Protocol(
                                "archive list position overflows i32".into(),
                            )));
                        }
                    };
                    match db::archive::exists(&mut *tx, arcid).await {
                        Ok(true) => {}
                        Ok(false) => {
                            warn!("Skipping tankoubon link: archive {arcid} not in database");
                            continue;
                        }
                        Err(e) => {
                            warn!("Could not check existence of {arcid}: {e}");
                            continue;
                        }
                    }
                    if let Err(e) =
                        db::backup::insert_tankoubon_archive(&mut *tx, tankid, arcid, position)
                            .await
                    {
                        warn!("Failed to link archive {arcid} to tankoubon {tankid}: {e}");
                    }
                }
            }
        }
    }

    // Restore archive metadata
    if let Some(archives) = backup["archives"].as_array() {
        for arc in archives {
            let arcid = arc["arcid"].as_str().unwrap_or_default();
            let title = arc["title"].as_str().unwrap_or_default();
            let summary = arc["summary"].as_str().unwrap_or_default();
            let thumbhash = arc["thumbhash"].as_str().unwrap_or_default();
            let tags_str = arc["tags"].as_str().unwrap_or_default();

            let exists =
                db::backup::update_archive_metadata(&mut *tx, arcid, title, summary, thumbhash)
                    .await
                    .map_err(|e| {
                        error!("Failed to update metadata for {arcid}: {e}");
                        BackupError::Db(e)
                    })?;

            if !exists {
                // Archive not present locally; skip silently, matching Perl behavior.
                continue;
            }

            info!("Restoring metadata for Archive {arcid}...");

            if !tags_str.is_empty() {
                db::backup::delete_archive_tags(&mut *tx, arcid)
                    .await
                    .map_err(|e| {
                        error!("Failed to delete tags for {arcid}: {e}");
                        BackupError::Db(e)
                    })?;

                for raw_tag in tags_str.split(',') {
                    let tag = raw_tag.trim();
                    if tag.is_empty() {
                        continue;
                    }
                    let (namespace, value) = parse_tag(tag);
                    match db::backup::upsert_tag_get_id(&mut *tx, namespace, value).await {
                        Err(e) => {
                            warn!("Failed to upsert tag '{tag}' for {arcid}: {e}");
                        }
                        Ok(tagid) => {
                            if let Err(e) = db::backup::insert_archive_tag(
                                &mut *tx, arcid, tagid, namespace, value,
                            )
                            .await
                            {
                                warn!("Failed to link tag '{tag}' to {arcid}: {e}");
                            }
                        }
                    }
                }
            }
        }
    }

    tx.commit().await.map_err(|e| {
        error!("Failed to commit restore transaction: {e}");
        BackupError::Db(e)
    })?;

    info!("Backup restore completed.");
    Ok(())
}

/// Splits a raw tag string into `(namespace, value)`.
///
/// `"artist:wada rco"` -> `("artist", "wada rco")`
/// `"artbook"`         -> `("", "artbook")`
pub fn parse_tag(tag: &str) -> (&str, &str) {
    if let Some(colon) = tag.find(':') {
        let ns = &tag[..colon];
        let val = &tag[colon + 1..];
        (ns, val)
    } else {
        ("", tag)
    }
}

#[cfg(test)]
mod tests {
    use super::parse_tag;

    #[test]
    fn test_parse_tag_namespaced() {
        assert_eq!(parse_tag("artist:wada rco"), ("artist", "wada rco"));
    }

    #[test]
    fn test_parse_tag_bare() {
        assert_eq!(parse_tag("artbook"), ("", "artbook"));
    }

    #[test]
    fn test_parse_tag_namespace_with_colon_in_value() {
        // Only the first colon is the separator.
        assert_eq!(parse_tag("source:http://example.com"), ("source", "http://example.com"));
    }

    #[test]
    fn test_parse_tag_empty_namespace() {
        assert_eq!(parse_tag(":value"), ("", "value"));
    }
}
