//! Backup and restore SQL queries.

use sqlx::PgPool;

#[derive(sqlx::FromRow)]
pub struct CategoryRow {
    pub catid: String,
    pub name: String,
    pub search: String,
}

#[derive(sqlx::FromRow)]
pub struct CategoryArchiveRow {
    pub arcid: String,
}

#[derive(sqlx::FromRow)]
pub struct TankoubonRow {
    pub tankid: String,
    pub name: String,
}

#[derive(sqlx::FromRow)]
pub struct TankoubonArchiveRow {
    pub arcid: String,
}

#[derive(sqlx::FromRow)]
pub struct BackupArchiveRow {
    pub arcid: String,
    pub filename: String,
    pub title: String,
    pub summary: Option<String>,
    pub thumbhash: Option<String>,
    pub tags: String,
}

#[derive(sqlx::FromRow)]
pub struct TagStatRow {
    pub namespace: String,
    pub value: String,
    pub weight: i64,
}
pub async fn list_categories(pool: &PgPool) -> Result<Vec<CategoryRow>, sqlx::Error> {
    sqlx::query_as::<_, CategoryRow>(
        r#"
        SELECT catid, name, COALESCE(search, '') AS search
        FROM lrr_category
        ORDER BY catid
        "#,
    )
    .fetch_all(pool)
    .await
}

pub async fn list_category_archives(
    pool: &PgPool,
    catid: &str,
) -> Result<Vec<CategoryArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, CategoryArchiveRow>(
        r#"
        SELECT arcid
        FROM lrr_category_to_archive_map
        WHERE catid = $1
        ORDER BY arcid
        "#,
    )
    .bind(catid)
    .fetch_all(pool)
    .await
}
pub async fn list_tankoubons(pool: &PgPool) -> Result<Vec<TankoubonRow>, sqlx::Error> {
    sqlx::query_as::<_, TankoubonRow>(
        r#"
        SELECT tankid, name
        FROM lrr_tank
        ORDER BY tankid
        "#,
    )
    .fetch_all(pool)
    .await
}

pub async fn list_tankoubon_archives(
    pool: &PgPool,
    tankid: &str,
) -> Result<Vec<TankoubonArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, TankoubonArchiveRow>(
        r#"
        SELECT arcid
        FROM lrr_tank_to_archive_map
        WHERE tankid = $1
        ORDER BY position ASC, arcid ASC
        "#,
    )
    .bind(tankid)
    .fetch_all(pool)
    .await
}
pub async fn list_archives_for_backup(
    pool: &PgPool,
) -> Result<Vec<BackupArchiveRow>, sqlx::Error> {
    sqlx::query_as::<_, BackupArchiveRow>(
        r#"
        SELECT
            a.arcid,
            a.filename,
            a.title,
            a.summary,
            a.thumbhash,
            COALESCE(
                string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                    ORDER BY t.tagid
                ),
                ''
            ) AS tags
        FROM lrr_archive a
        LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
        GROUP BY a.arcid, a.filename, a.title, a.summary, a.thumbhash
        ORDER BY a.arcid
        "#,
    )
    .fetch_all(pool)
    .await
}
pub async fn upsert_category(
    conn: &mut sqlx::PgConnection,
    catid: &str,
    name: &str,
    search: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO lrr_category (catid, name, pinned, search)
        VALUES ($1, $2, FALSE, $3)
        ON CONFLICT (catid) DO UPDATE
            SET name = EXCLUDED.name, search = EXCLUDED.search
        "#,
    )
    .bind(catid)
    .bind(name)
    .bind(search)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

pub async fn insert_category_archive(
    conn: &mut sqlx::PgConnection,
    catid: &str,
    arcid: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO lrr_category_to_archive_map (catid, arcid, update_date)
        VALUES ($1, $2, CURRENT_DATE)
        ON CONFLICT DO NOTHING
        "#,
    )
    .bind(catid)
    .bind(arcid)
    .execute(&mut *conn)
    .await?;
    Ok(())
}
pub async fn upsert_tankoubon(
    conn: &mut sqlx::PgConnection,
    tankid: &str,
    name: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO lrr_tank (tankid, name, summary, tags)
        VALUES ($1, $2, '', '')
        ON CONFLICT (tankid) DO UPDATE
            SET name = EXCLUDED.name
        "#,
    )
    .bind(tankid)
    .bind(name)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

pub async fn insert_tankoubon_archive(
    conn: &mut sqlx::PgConnection,
    tankid: &str,
    arcid: &str,
    position: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO lrr_tank_to_archive_map (tankid, arcid, position, update_date)
        VALUES ($1, $2, $3, CURRENT_DATE)
        ON CONFLICT DO NOTHING
        "#,
    )
    .bind(tankid)
    .bind(arcid)
    .bind(position)
    .execute(&mut *conn)
    .await?;
    Ok(())
}
pub async fn update_archive_metadata(
    conn: &mut sqlx::PgConnection,
    arcid: &str,
    title: &str,
    summary: &str,
    thumbhash: &str,
) -> Result<bool, sqlx::Error> {
    let rows = sqlx::query(
        r#"
        UPDATE lrr_archive
        SET title = $2, summary = $3, thumbhash = $4
        WHERE arcid = $1
        "#,
    )
    .bind(arcid)
    .bind(title)
    .bind(summary)
    .bind(thumbhash)
    .execute(&mut *conn)
    .await?;
    Ok(rows.rows_affected() > 0)
}

pub async fn delete_archive_tags<'e, E>(executor: E, arcid: &str) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("DELETE FROM lrr_archive_to_tag_map WHERE arcid = $1")
        .bind(arcid)
        .execute(executor)
        .await?;
    Ok(())
}

pub async fn upsert_tag_get_id<'e>(
    executor: &'e mut sqlx::PgConnection,
    namespace: &str,
    value: &str,
) -> Result<i32, sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO lrr_tag (namespace, value)
        VALUES ($1, $2)
        ON CONFLICT (namespace, value) DO NOTHING
        "#,
    )
    .bind(namespace)
    .bind(value)
    .execute(&mut *executor)
    .await?;

    sqlx::query_scalar(
        r#"SELECT tagid FROM lrr_tag WHERE namespace = $1 AND value = $2"#,
    )
    .bind(namespace)
    .bind(value)
    .fetch_one(&mut *executor)
    .await
}

pub async fn insert_archive_tag<'e, E>(
    executor: E,
    arcid: &str,
    tagid: i32,
    namespace: &str,
    value: &str,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
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
    .execute(executor)
    .await?;
    Ok(())
}

/// Deletes all categories, tankoubons, and their archive mappings.
/// Caller must supply an executor; runs inside the caller's transaction.
pub async fn clean_categories_and_tanks(conn: &mut sqlx::PgConnection) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM lrr_category_to_archive_map").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_category").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_tank_to_archive_map").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_tank").execute(&mut *conn).await?;
    Ok(())
}

/// Removes orphan tag rows (tags with no archive references).
/// Returns count of deleted rows.
pub async fn delete_orphan_tags(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(
        r#"
        DELETE FROM lrr_tag
        WHERE tagid NOT IN (SELECT DISTINCT tagid FROM lrr_archive_to_tag_map)
        "#,
    )
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

/// Clears isnew on all archives in one UPDATE.
pub async fn clear_isnew_all(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let result = sqlx::query("UPDATE lrr_archive SET isnew = FALSE")
        .execute(pool)
        .await?;
    Ok(result.rows_affected())
}

/// Drops all archives and their dependent rows in FK-safe order.
/// Caller must supply a connection; runs inside the caller's transaction.
pub async fn drop_all_archives(conn: &mut sqlx::PgConnection) -> Result<u64, sqlx::Error> {
    // Delete child tables first to satisfy FK constraints.
    // lrr_stamp has no CASCADE; must precede lrr_archive.
    sqlx::query("DELETE FROM lrr_stamp").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_toc").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_archive_to_tag_map").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_category_to_archive_map").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_tank_to_archive_map").execute(&mut *conn).await?;
    // lrr_filemap has ON DELETE CASCADE but explicit delete is consistent.
    sqlx::query("DELETE FROM lrr_filemap").execute(&mut *conn).await?;

    let result = sqlx::query("DELETE FROM lrr_archive")
        .execute(&mut *conn)
        .await?;

    // Remove orphan category/tank/tag rows.
    sqlx::query("DELETE FROM lrr_category").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_tank").execute(&mut *conn).await?;
    sqlx::query("DELETE FROM lrr_tag").execute(&mut *conn).await?;

    Ok(result.rows_affected())
}
pub async fn get_tag_stats(
    pool: &PgPool,
    minweight: i64,
    excluded_namespaces: &[String],
) -> Result<Vec<TagStatRow>, sqlx::Error> {
    if excluded_namespaces.is_empty() {
        sqlx::query_as::<_, TagStatRow>(
            r#"
            SELECT
                LOWER(atm.namespace) AS namespace,
                LOWER(atm.value)     AS value,
                COUNT(*)::BIGINT     AS weight
            FROM lrr_archive_to_tag_map atm
            GROUP BY LOWER(atm.namespace), LOWER(atm.value)
            HAVING COUNT(*) >= $1
            ORDER BY weight DESC
            "#,
        )
        .bind(minweight)
        .fetch_all(pool)
        .await
    } else {
        // Build the NOT IN list dynamically; sqlx doesn't support binding slice
        // directly into a NOT IN clause, so we parameterise individually.
        let placeholders: String = excluded_namespaces
            .iter()
            .enumerate()
            .map(|(i, _)| format!("${}", i + 2))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            r#"
            SELECT
                LOWER(atm.namespace) AS namespace,
                LOWER(atm.value)     AS value,
                COUNT(*)::BIGINT     AS weight
            FROM lrr_archive_to_tag_map atm
            WHERE LOWER(atm.namespace) NOT IN ({placeholders})
            GROUP BY LOWER(atm.namespace), LOWER(atm.value)
            HAVING COUNT(*) >= $1
            ORDER BY weight DESC
            "#
        );
        // AssertSqlSafe rationale: `sql` is fully constructed from integer-indexed
        // positional parameters ($1, $2, …); no user-supplied strings are interpolated.
        let mut q = sqlx::query_as::<_, TagStatRow>(sqlx::AssertSqlSafe(sql)).bind(minweight);
        for ns in excluded_namespaces {
            q = q.bind(ns.to_lowercase());
        }
        q.fetch_all(pool).await
    }
}
