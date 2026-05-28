//! Archive SQL queries.

use sqlx::PgPool;

/// Raw row shape returned by `list_all`. Mirrors the column projection of the
/// query, including the `string_agg`-built `tags` column.
#[derive(sqlx::FromRow)]
pub struct ArchiveRow {
    pub arcid: String,
    pub filename: String,
    pub title: String,
    pub summary: Option<String>,
    pub isnew: bool,
    pub progress: i32,
    pub pagecount: i32,
    pub lastreadtime: i64,
    pub arcsize: Option<i64>,
    pub extension: Option<String>,
    pub tags: String,
}
pub async fn list_all(pool: &PgPool) -> Result<Vec<ArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, ArchiveRow>(
        r#"
        SELECT
            a.arcid,
            a.filename,
            a.title,
            a.summary,
            a.isnew,
            a.progress,
            a.pagecount,
            a.lastreadtime,
            a.arcsize,
            a.extension,
            COALESCE(
                string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                ),
                ''
            ) AS tags
        FROM lrr_archive a
        LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
        GROUP BY a.arcid
        ORDER BY a.title
        "#,
    )
    .fetch_all(pool)
    .await
}

/// Fetches metadata + tags for a single archive. Returns `None` if not found.
pub async fn get_one(pool: &PgPool, arcid: &str) -> Result<Option<ArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, ArchiveRow>(
        r#"
        SELECT
            a.arcid,
            a.filename,
            a.title,
            a.summary,
            a.isnew,
            a.progress,
            a.pagecount,
            a.lastreadtime,
            a.arcsize,
            a.extension,
            COALESCE(
                string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                ),
                ''
            ) AS tags
        FROM lrr_archive a
        LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
        WHERE a.arcid = $1
        GROUP BY a.arcid
        "#,
    )
    .bind(arcid)
    .fetch_optional(pool)
    .await
}

pub async fn count(pool: &PgPool) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar("SELECT COUNT(*) FROM lrr_archive")
        .fetch_one(pool)
        .await
}

pub async fn exists<'e, E>(executor: E, arcid: &str) -> Result<bool, sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query_scalar::<_, bool>("SELECT EXISTS (SELECT 1 FROM lrr_archive WHERE arcid = $1)")
        .bind(arcid)
        .fetch_one(executor)
        .await
}

pub struct NewArchive<'a> {
    pub arcid: &'a str,
    pub filename: &'a str,
    pub extension: Option<&'a str>,
    pub title: &'a str,
    pub summary: Option<&'a str>,
    pub pagecount: i32,
    pub arcsize: i64,
}

pub async fn insert<'e, E>(executor: E, archive: &NewArchive<'_>) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        r#"
        INSERT INTO lrr_archive
            (arcid, filename, extension, isnew, lastreadtime, pagecount, progress, title, summary, arcsize)
        VALUES ($1, $2, $3, TRUE, 0, $4, 0, $5, $6, $7)
        "#,
    )
    .bind(archive.arcid)
    .bind(archive.filename)
    .bind(archive.extension)
    .bind(archive.pagecount)
    .bind(archive.title)
    .bind(archive.summary)
    .bind(archive.arcsize)
    .execute(executor)
    .await?;
    Ok(())
}
pub async fn set_isnew<'e, E>(executor: E, arcid: &str, isnew: bool) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("UPDATE lrr_archive SET isnew = $1 WHERE arcid = $2")
        .bind(isnew)
        .bind(arcid)
        .execute(executor)
        .await?;
    Ok(())
}

/// Result of `update_progress_in_tx`: distinguishes not-found from out-of-range.
pub enum UpdateProgressOutcome {
    /// Archive not found.
    NotFound,
    /// Page is outside `[1, pagecount]`; carries the actual pagecount.
    OutOfRange(i32),
    /// Success; carries `(page, lastreadtime_epoch)`.
    Ok(i32, i64),
}

/// Updates reading progress inside an already-opened transaction.
/// Validates page bounds (1..=pagecount) before issuing the UPDATE.
pub async fn update_progress_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    arcid: &str,
    page: i32,
    time: i64,
) -> Result<UpdateProgressOutcome, sqlx::Error> {
    let pagecount: Option<i32> =
        sqlx::query_scalar("SELECT pagecount FROM lrr_archive WHERE arcid = $1")
            .bind(arcid)
            .fetch_optional(&mut **tx)
            .await?;

    let pagecount = match pagecount {
        Some(pc) => pc,
        None => return Ok(UpdateProgressOutcome::NotFound),
    };

    if page <= 0 || page > pagecount {
        return Ok(UpdateProgressOutcome::OutOfRange(pagecount));
    }

    sqlx::query("UPDATE lrr_archive SET progress = $1, lastreadtime = $2 WHERE arcid = $3")
        .bind(page)
        .bind(time)
        .bind(arcid)
        .execute(&mut **tx)
        .await?;

    Ok(UpdateProgressOutcome::Ok(page, time))
}

/// Updates title for the given archive within an already-opened transaction executor.
pub async fn set_title<'e, E>(executor: E, arcid: &str, title: &str) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("UPDATE lrr_archive SET title = $1 WHERE arcid = $2")
        .bind(title)
        .bind(arcid)
        .execute(executor)
        .await?;
    Ok(())
}

/// Updates summary for the given archive.
pub async fn set_summary<'e, E>(executor: E, arcid: &str, summary: &str) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("UPDATE lrr_archive SET summary = $1 WHERE arcid = $2")
        .bind(summary)
        .bind(arcid)
        .execute(executor)
        .await?;
    Ok(())
}

/// Replaces all tags for an archive atomically: deletes old tag-map rows,
/// upserts tags into `lrr_tag`, then re-inserts mapping rows.
/// Must be called inside a transaction.
pub async fn set_tags(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    arcid: &str,
    tags_str: &str,
) -> Result<(), sqlx::Error> {
    // Delete existing tag mappings for this archive.
    sqlx::query("DELETE FROM lrr_archive_to_tag_map WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;

    // Parse "namespace:value, namespace:value, ..." tag string.
    for raw in tags_str.split(',') {
        let tag = raw.trim();
        if tag.is_empty() {
            continue;
        }
        let (namespace, value) = if let Some(colon) = tag.find(':') {
            let ns = tag[..colon].trim();
            let val = tag[colon + 1..].trim();
            (ns, val)
        } else {
            ("", tag)
        };

        if value.is_empty() {
            continue;
        }

        // Insert the tag if it does not exist, then SELECT to get the tagid.
        // DO NOTHING avoids a spurious row-update lock on existing tags.
        // Mirrors PgDatabase.pm::set_archive_tags insert pattern.
        sqlx::query(
            "INSERT INTO lrr_tag (namespace, value) VALUES ($1, $2) ON CONFLICT (namespace, value) DO NOTHING",
        )
        .bind(namespace)
        .bind(value)
        .execute(&mut **tx)
        .await?;
        let tagid: i32 = sqlx::query_scalar(
            "SELECT tagid FROM lrr_tag WHERE namespace = $1 AND value = $2",
        )
        .bind(namespace)
        .bind(value)
        .fetch_one(&mut **tx)
        .await?;

        // Insert into archive-to-tag map.
        sqlx::query(
            r#"
            INSERT INTO lrr_archive_to_tag_map (arcid, tagid, namespace, value, update_date)
            VALUES ($1, $2, $3, $4, CURRENT_DATE)
            ON CONFLICT DO NOTHING
            "#,
        )
        .bind(arcid)
        .bind(tagid)
        .bind(namespace)
        .bind(value)
        .execute(&mut **tx)
        .await?;
    }

    Ok(())
}

/// Deletes an archive and all its child rows from junction tables (no FK cascade in schema).
/// Order: lrr_stamp -> tag-map -> category-map -> tank-map -> toc -> filemap -> archive.
/// lrr_stamp must be first: it declares a non-cascading FK to lrr_archive (0006_lrr_stamps.sql).
/// Caller must handle filesystem cleanup after commit.
pub async fn delete(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    arcid: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM lrr_stamp WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_archive_to_tag_map WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_category_to_archive_map WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_tank_to_archive_map WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_toc WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_filemap WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_archive WHERE arcid = $1")
        .bind(arcid)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// Returns all archive IDs that have no "meaningful" tags (mirrors LRR Stats logic).
pub async fn list_untagged(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        r#"
        SELECT a.arcid
        FROM lrr_archive a
        WHERE NOT EXISTS (
            SELECT 1
            FROM lrr_archive_to_tag_map atm
            INNER JOIN lrr_tag t ON atm.tagid = t.tagid
            WHERE atm.arcid = a.arcid
            AND t.namespace NOT IN (
                'artist', 'parody', 'series', 'language', 'event',
                'group', 'date_added', 'timestamp', 'source'
            )
        )
        ORDER BY a.arcid
        "#,
    )
    .fetch_all(pool)
    .await
}

/// Batch-fetches (arcid, path) pairs for a list of arcids from the filemap.
/// Archives with no filemap entry are omitted from the result.
pub async fn list_paths_for_arcids(
    pool: &PgPool,
    arcids: &[String],
) -> Result<Vec<(String, String)>, sqlx::Error> {
    sqlx::query_as::<_, (String, String)>(
        "SELECT arcid, path FROM lrr_filemap WHERE arcid = ANY($1)",
    )
    .bind(arcids)
    .fetch_all(pool)
    .await
}

/// Returns the filemap path and pagecount for an archive, or `None` if missing.
pub async fn get_path_and_pagecount(
    pool: &PgPool,
    arcid: &str,
) -> Result<Option<(String, i32)>, sqlx::Error> {
    sqlx::query_as::<_, (String, i32)>(
        r#"
        SELECT f.path, a.pagecount
        FROM lrr_archive a
        JOIN lrr_filemap f ON f.arcid = a.arcid
        WHERE a.arcid = $1
        "#,
    )
    .bind(arcid)
    .fetch_optional(pool)
    .await
}

/// Returns the filemap path for an archive, or `None` if missing.
pub async fn get_path(pool: &PgPool, arcid: &str) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT path FROM lrr_filemap WHERE arcid = $1",
    )
    .bind(arcid)
    .fetch_optional(pool)
    .await
}

/// Returns the title for a given arcid, or `None` if not found.
pub async fn get_title(pool: &PgPool, arcid: &str) -> Result<Option<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>("SELECT title FROM lrr_archive WHERE arcid = $1")
        .bind(arcid)
        .fetch_optional(pool)
        .await
}

/// Returns the categories that contain this archive.
pub async fn list_categories_for_archive(
    pool: &PgPool,
    arcid: &str,
) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT catid FROM lrr_category_to_archive_map WHERE arcid = $1 ORDER BY catid",
    )
    .bind(arcid)
    .fetch_all(pool)
    .await
}

/// Returns the tankoubon IDs that contain this archive.
pub async fn list_tankoubons_for_archive(
    pool: &PgPool,
    arcid: &str,
) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT tankid FROM lrr_tank_to_archive_map WHERE arcid = $1 ORDER BY tankid",
    )
    .bind(arcid)
    .fetch_all(pool)
    .await
}

/// A single ToC entry row.
#[derive(sqlx::FromRow)]
pub struct TocRow {
    pub page: i32,
    pub title: String,
}

/// Returns all ToC entries for an archive ordered by page.
pub async fn list_toc(pool: &PgPool, arcid: &str) -> Result<Vec<TocRow>, sqlx::Error> {
    sqlx::query_as::<_, TocRow>(
        "SELECT page, title FROM lrr_toc WHERE arcid = $1 ORDER BY page",
    )
    .bind(arcid)
    .fetch_all(pool)
    .await
}

/// A ToC entry row that also carries the arcid, for batch lookups.
#[derive(sqlx::FromRow)]
pub struct TocBatchRow {
    pub arcid: String,
    pub page: i32,
    pub title: String,
}

/// Batch-fetches all ToC entries for the given list of arcids.
/// Returns rows in (arcid, page) order. Callers partition by arcid.
pub async fn list_tocs_for_arcids(
    pool: &PgPool,
    arcids: &[String],
) -> Result<Vec<TocBatchRow>, sqlx::Error> {
    sqlx::query_as::<_, TocBatchRow>(
        "SELECT arcid, page, title FROM lrr_toc WHERE arcid = ANY($1) ORDER BY arcid, page",
    )
    .bind(arcids)
    .fetch_all(pool)
    .await
}

/// Upserts a ToC entry (insert or update on (arcid, page) conflict).
pub async fn upsert_toc<'e, E>(
    executor: E,
    arcid: &str,
    page: i32,
    title: &str,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        r#"
        INSERT INTO lrr_toc (arcid, page, title)
        VALUES ($1, $2, $3)
        ON CONFLICT (arcid, page) DO UPDATE SET title = EXCLUDED.title
        "#,
    )
    .bind(arcid)
    .bind(page)
    .bind(title)
    .execute(executor)
    .await?;
    Ok(())
}

/// Deletes a ToC entry for (arcid, page).
pub async fn delete_toc<'e, E>(
    executor: E,
    arcid: &str,
    page: i32,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("DELETE FROM lrr_toc WHERE arcid = $1 AND page = $2")
        .bind(arcid)
        .bind(page)
        .execute(executor)
        .await?;
    Ok(())
}

/// Batch-fetch archive rows for a given list of arcids using `ANY($1)`.
/// Returned order is unspecified; callers should re-order by their own key list.
pub async fn list_by_arcids(pool: &PgPool, arcids: &[String]) -> Result<Vec<ArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, ArchiveRow>(
        r#"
        SELECT
            a.arcid,
            a.filename,
            a.title,
            a.summary,
            a.isnew,
            a.progress,
            a.pagecount,
            a.lastreadtime,
            a.arcsize,
            a.extension,
            COALESCE(
                string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                ),
                ''
            ) AS tags
        FROM lrr_archive a
        LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
        WHERE a.arcid = ANY($1)
        GROUP BY a.arcid
        "#,
    )
    .bind(arcids)
    .fetch_all(pool)
    .await
}

/// Fetches a single archive as an `ArchiveRow` (same projection as `list_all`),
/// or `None` if not found.
pub async fn get_by_arcid(pool: &PgPool, arcid: &str) -> Result<Option<ArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, ArchiveRow>(
        r#"
        SELECT
            a.arcid,
            a.filename,
            a.title,
            a.summary,
            a.isnew,
            a.progress,
            a.pagecount,
            a.lastreadtime,
            a.arcsize,
            a.extension,
            COALESCE(
                string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                ),
                ''
            ) AS tags
        FROM lrr_archive a
        LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
        WHERE a.arcid = $1
        GROUP BY a.arcid
        "#,
    )
    .bind(arcid)
    .fetch_optional(pool)
    .await
}

/// Returns `(arcid, filename)` pairs for all archives; used by `clean_database`.
pub async fn list_paths_for_clean(pool: &PgPool) -> Result<Vec<(String, String)>, sqlx::Error> {
    sqlx::query_as::<_, (String, String)>("SELECT arcid, filename FROM lrr_archive")
        .fetch_all(pool)
        .await
}

/// Returns the pagecount for an archive, or `None` if the archive does not exist.
pub async fn get_pagecount(pool: &PgPool, arcid: &str) -> Result<Option<i32>, sqlx::Error> {
    sqlx::query_scalar::<_, i32>("SELECT pagecount FROM lrr_archive WHERE arcid = $1")
        .bind(arcid)
        .fetch_optional(pool)
        .await
}

/// Updates pagecount for an archive (called after file extraction confirms actual page count).
pub async fn update_pagecount<'e, E>(
    executor: E,
    arcid: &str,
    pagecount: i32,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("UPDATE lrr_archive SET pagecount = $1 WHERE arcid = $2")
        .bind(pagecount)
        .bind(arcid)
        .execute(executor)
        .await?;
    Ok(())
}

/// Like `list_all_paginated` but INNER JOINs `lrr_filemap` so only archives
/// with a known backing file path are returned.
///
pub async fn list_all_paginated_with_file(
    pool: &PgPool,
    offset: i64,
    limit: i64,
) -> Result<Vec<ArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, ArchiveRow>(
        r#"
        SELECT
            a.arcid,
            a.filename,
            a.title,
            a.summary,
            a.isnew,
            a.progress,
            a.pagecount,
            a.lastreadtime,
            a.arcsize,
            a.extension,
            COALESCE(
                string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                ),
                ''
            ) AS tags
        FROM lrr_archive a
        INNER JOIN lrr_filemap f ON f.arcid = a.arcid
        LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
        GROUP BY a.arcid
        ORDER BY a.title
        LIMIT $1 OFFSET $2
        "#,
    )
    .bind(limit)
    .bind(offset)
    .fetch_all(pool)
    .await
}

/// Paginated category archive fetch: archives in a static category that have
/// a filemap entry, title-ordered.
///
pub async fn list_by_category_paginated(
    pool: &PgPool,
    catid: &str,
    offset: i64,
    limit: i64,
) -> Result<Vec<ArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, ArchiveRow>(
        r#"
        SELECT
            a.arcid,
            a.filename,
            a.title,
            a.summary,
            a.isnew,
            a.progress,
            a.pagecount,
            a.lastreadtime,
            a.arcsize,
            a.extension,
            COALESCE(
                string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                ),
                ''
            ) AS tags
        FROM lrr_archive a
        INNER JOIN lrr_category_to_archive_map cam ON cam.arcid = a.arcid
        INNER JOIN lrr_filemap f ON f.arcid = a.arcid
        LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
        WHERE cam.catid = $1
        GROUP BY a.arcid
        ORDER BY a.title
        LIMIT $2 OFFSET $3
        "#,
    )
    .bind(catid)
    .bind(limit)
    .bind(offset)
    .fetch_all(pool)
    .await
}
