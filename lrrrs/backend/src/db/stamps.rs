//! Stamps SQL queries.

use sqlx::PgPool;

/// Full stamp row from `lrr_stamp`.
#[derive(sqlx::FromRow)]
pub struct StampRow {
    pub stampid:  String,
    pub position: String,
    pub content:  String,
}

/// Returns the stamp identified by `stampid`, or `None` if absent.
pub async fn get(pool: &PgPool, stampid: &str) -> Result<Option<StampRow>, sqlx::Error> {
    sqlx::query_as::<_, StampRow>(
        "SELECT stampid, position, content \
         FROM lrr_stamp WHERE stampid = $1",
    )
    .bind(stampid)
    .fetch_optional(pool)
    .await
}

/// Returns all stamps for the given (arcid, page) pair.
pub async fn list_by_page(
    pool: &PgPool,
    arcid: &str,
    page: i32,
) -> Result<Vec<StampRow>, sqlx::Error> {
    sqlx::query_as::<_, StampRow>(
        "SELECT stampid, position, content \
         FROM lrr_stamp WHERE arcid = $1 AND page = $2",
    )
    .bind(arcid)
    .bind(page)
    .fetch_all(pool)
    .await
}

/// Returns the distinct page numbers (as strings) that have at least one stamp
/// in the given archive.
pub async fn list_stamped_pages(
    pool: &PgPool,
    arcid: &str,
) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT DISTINCT page::text FROM lrr_stamp WHERE arcid = $1 ORDER BY page",
    )
    .bind(arcid)
    .fetch_all(pool)
    .await
}

/// Inserts a new stamp row.
pub async fn insert<'e, E>(
    executor: E,
    stampid: &str,
    arcid: &str,
    page: i32,
    position: &str,
    content: &str,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        "INSERT INTO lrr_stamp (stampid, arcid, page, position, content) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(stampid)
    .bind(arcid)
    .bind(page)
    .bind(position)
    .bind(content)
    .execute(executor)
    .await?;
    Ok(())
}

/// Updates position and content for the given stamp.  Returns `true` if a row
/// was updated, `false` if the stampid did not exist.
pub async fn update<'e, E>(
    executor: E,
    stampid: &str,
    position: &str,
    content: &str,
) -> Result<bool, sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    let result = sqlx::query(
        "UPDATE lrr_stamp SET position = $1, content = $2 WHERE stampid = $3",
    )
    .bind(position)
    .bind(content)
    .bind(stampid)
    .execute(executor)
    .await?;
    Ok(result.rows_affected() > 0)
}

/// Deletes a stamp by stampid.  Returns `true` if a row was deleted, `false`
/// if the stampid did not exist.
pub async fn delete<'e, E>(executor: E, stampid: &str) -> Result<bool, sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    let result = sqlx::query("DELETE FROM lrr_stamp WHERE stampid = $1")
        .bind(stampid)
        .execute(executor)
        .await?;
    Ok(result.rows_affected() > 0)
}
