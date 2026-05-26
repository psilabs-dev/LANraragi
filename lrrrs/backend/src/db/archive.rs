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
    pub lastreadtime: i32,
    pub arcsize: Option<i64>,
    pub extension: Option<String>,
    pub tags: String,
}

// port of LANraragi::Model::Archive::generate_archive_list
// commit hash: f61ca82e
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
