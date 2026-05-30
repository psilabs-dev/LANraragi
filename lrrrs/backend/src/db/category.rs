//! Category SQL queries.

use sqlx::PgPool;

/// Full category row from `lrr_category`.
#[derive(sqlx::FromRow)]
pub struct CategoryRow {
    pub catid: String,
    pub name: String,
    pub pinned: bool,
    pub search: String,
}

/// Fetches all categories ordered by catid.
pub async fn list_all(pool: &PgPool) -> Result<Vec<CategoryRow>, sqlx::Error> {
    sqlx::query_as::<_, CategoryRow>(
        "SELECT catid, name, pinned, COALESCE(search, '') AS search \
         FROM lrr_category ORDER BY catid",
    )
    .fetch_all(pool)
    .await
}

/// Fetches a single category row, or `None` if not found.
pub async fn get<'e, E>(executor: E, catid: &str) -> Result<Option<CategoryRow>, sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query_as::<_, CategoryRow>(
        "SELECT catid, name, pinned, COALESCE(search, '') AS search \
         FROM lrr_category WHERE catid = $1",
    )
    .bind(catid)
    .fetch_optional(executor)
    .await
}

/// Returns true if a category with the given catid exists.
pub async fn exists(pool: &PgPool, catid: &str) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM lrr_category WHERE catid = $1)",
    )
    .bind(catid)
    .fetch_one(pool)
    .await
}

/// Returns all arcids mapped to a static category, ordered by arcid.
pub async fn list_archives(pool: &PgPool, catid: &str) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT arcid FROM lrr_category_to_archive_map WHERE catid = $1 ORDER BY arcid",
    )
    .bind(catid)
    .fetch_all(pool)
    .await
}

/// Returns true if the (catid, arcid) pair already exists in the map.
pub async fn archive_in_category<'e, E>(
    executor: E,
    catid: &str,
    arcid: &str,
) -> Result<bool, sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM lrr_category_to_archive_map \
         WHERE catid = $1 AND arcid = $2)",
    )
    .bind(catid)
    .bind(arcid)
    .fetch_one(executor)
    .await
}

/// Inserts (catid, arcid) into the map. Callers must pre-check that the
/// category is static and the archive exists.
pub async fn add_archive<'e, E>(executor: E, catid: &str, arcid: &str) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        "INSERT INTO lrr_category_to_archive_map (catid, arcid, update_date) \
         VALUES ($1, $2, CURRENT_DATE) \
         ON CONFLICT (catid, arcid) DO NOTHING",
    )
    .bind(catid)
    .bind(arcid)
    .execute(executor)
    .await?;
    Ok(())
}

/// Removes (catid, arcid) from the map.
pub async fn remove_archive<'e, E>(
    executor: E,
    catid: &str,
    arcid: &str,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        "DELETE FROM lrr_category_to_archive_map WHERE catid = $1 AND arcid = $2",
    )
    .bind(catid)
    .bind(arcid)
    .execute(executor)
    .await?;
    Ok(())
}

/// Upserts a category row. If `catid` already exists the row is updated;
/// otherwise a new row is inserted.
pub async fn upsert<'e, E>(
    executor: E,
    catid: &str,
    name: &str,
    search: Option<&str>,
    pinned: bool,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        "INSERT INTO lrr_category (catid, name, search, pinned) \
         VALUES ($1, $2, $3, $4) \
         ON CONFLICT (catid) DO UPDATE \
         SET name = EXCLUDED.name, search = EXCLUDED.search, pinned = EXCLUDED.pinned",
    )
    .bind(catid)
    .bind(name)
    .bind(search)
    .bind(pinned)
    .execute(executor)
    .await?;
    Ok(())
}

/// Deletes the archive map entries and the category row in a single transaction.
pub async fn delete(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    catid: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM lrr_category_to_archive_map WHERE catid = $1")
        .bind(catid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_category WHERE catid = $1")
        .bind(catid)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// Returns the bookmark_link catid from lrr_config, or None if unset.
pub async fn get_bookmark_link<'e, E>(executor: E) -> Result<Option<String>, sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query_scalar::<_, Option<String>>(
        "SELECT bookmark_link FROM lrr_config WHERE id = 1",
    )
    .fetch_one(executor)
    .await
}

/// Sets (or clears) the bookmark_link in lrr_config.
pub async fn set_bookmark_link<'e, E>(
    executor: E,
    catid: Option<&str>,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("UPDATE lrr_config SET bookmark_link = $1 WHERE id = 1")
        .bind(catid)
        .execute(executor)
        .await?;
    Ok(())
}
