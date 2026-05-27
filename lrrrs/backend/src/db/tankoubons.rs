//! Tankoubon SQL queries.

use sqlx::PgPool;

/// Raw row from `lrr_tank`.
#[derive(sqlx::FromRow)]
pub struct TankRow {
    pub tankid: String,
    pub name: String,
    pub summary: Option<String>,
    pub tags: Option<String>,
}
pub async fn list_all(pool: &PgPool) -> Result<Vec<TankRow>, sqlx::Error> {
    sqlx::query_as::<_, TankRow>(
        "SELECT tankid, name, summary, tags FROM lrr_tank ORDER BY tankid",
    )
    .fetch_all(pool)
    .await
}
pub async fn get(pool: &PgPool, tankid: &str) -> Result<Option<TankRow>, sqlx::Error> {
    sqlx::query_as::<_, TankRow>(
        "SELECT tankid, name, summary, tags FROM lrr_tank WHERE tankid = $1",
    )
    .bind(tankid)
    .fetch_optional(pool)
    .await
}

pub async fn exists<'e, E>(executor: E, tankid: &str) -> Result<bool, sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query_scalar::<_, bool>("SELECT EXISTS (SELECT 1 FROM lrr_tank WHERE tankid = $1)")
        .bind(tankid)
        .fetch_one(executor)
        .await
}
pub async fn insert<'e, E>(executor: E, tankid: &str, name: &str) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        "INSERT INTO lrr_tank (tankid, name, summary, tags) VALUES ($1, $2, '', '')",
    )
    .bind(tankid)
    .bind(name)
    .execute(executor)
    .await?;
    Ok(())
}
pub async fn update_name<'e, E>(executor: E, tankid: &str, name: &str) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query("UPDATE lrr_tank SET name = $1 WHERE tankid = $2")
        .bind(name)
        .bind(tankid)
        .execute(executor)
        .await?;
    Ok(())
}
pub async fn update_metadata(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    tankid: &str,
    name: Option<&str>,
    summary: Option<&str>,
    tags: Option<&str>,
) -> Result<(), sqlx::Error> {
    if let Some(n) = name {
        sqlx::query("UPDATE lrr_tank SET name = $1 WHERE tankid = $2")
            .bind(n)
            .bind(tankid)
            .execute(&mut **tx)
            .await?;
    }
    if let Some(s) = summary {
        sqlx::query("UPDATE lrr_tank SET summary = $1 WHERE tankid = $2")
            .bind(s)
            .bind(tankid)
            .execute(&mut **tx)
            .await?;
    }
    if let Some(t) = tags {
        sqlx::query("UPDATE lrr_tank SET tags = $1 WHERE tankid = $2")
            .bind(t)
            .bind(tankid)
            .execute(&mut **tx)
            .await?;
    }
    Ok(())
}
pub async fn delete(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    tankid: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM lrr_tank_to_archive_map WHERE tankid = $1")
        .bind(tankid)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM lrr_tank WHERE tankid = $1")
        .bind(tankid)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// Fetch all archive IDs for a tankoubon in position order.
pub async fn get_archives(pool: &PgPool, tankid: &str) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT arcid FROM lrr_tank_to_archive_map WHERE tankid = $1 ORDER BY position",
    )
    .bind(tankid)
    .fetch_all(pool)
    .await
}

/// Fetch paginated archive IDs for a tankoubon.
pub async fn get_archives_page(
    pool: &PgPool,
    tankid: &str,
    limit: i64,
    offset: i64,
) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT arcid FROM lrr_tank_to_archive_map WHERE tankid = $1 ORDER BY position LIMIT $2 OFFSET $3",
    )
    .bind(tankid)
    .bind(limit)
    .bind(offset)
    .fetch_all(pool)
    .await
}

/// Sum of pagecount for all archives in the tankoubon. Returns 0 when empty.
pub async fn get_total_pagecount(pool: &PgPool, tankid: &str) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar::<_, i64>(
        r#"
        SELECT COALESCE(SUM(a.pagecount), 0)
        FROM lrr_tank_to_archive_map m
        JOIN lrr_archive a ON m.arcid = a.arcid
        WHERE m.tankid = $1
        "#,
    )
    .bind(tankid)
    .fetch_one(pool)
    .await
}

pub async fn count_archives(pool: &PgPool, tankid: &str) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM lrr_tank_to_archive_map WHERE tankid = $1",
    )
    .bind(tankid)
    .fetch_one(pool)
    .await
}

/// Check whether an archive is already a member of the tankoubon.
pub async fn mapping_exists(pool: &PgPool, tankid: &str, arcid: &str) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE tankid = $1 AND arcid = $2)",
    )
    .bind(tankid)
    .bind(arcid)
    .fetch_one(pool)
    .await
}
pub async fn add_archive(pool: &PgPool, tankid: &str, arcid: &str) -> Result<(), sqlx::Error> {
    // Append at max(position)+1.
    sqlx::query(
        r#"
        INSERT INTO lrr_tank_to_archive_map (tankid, arcid, position, update_date)
        VALUES (
            $1,
            $2,
            (SELECT COALESCE(MAX(position), 0) + 1 FROM lrr_tank_to_archive_map WHERE tankid = $1),
            CURRENT_DATE
        )
        "#,
    )
    .bind(tankid)
    .bind(arcid)
    .execute(pool)
    .await?;
    Ok(())
}
pub async fn remove_archive(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    tankid: &str,
    arcid: &str,
) -> Result<(), sqlx::Error> {
    // Find the position of the archive being removed.
    let pos: i32 = sqlx::query_scalar(
        "SELECT position FROM lrr_tank_to_archive_map WHERE tankid = $1 AND arcid = $2",
    )
    .bind(tankid)
    .bind(arcid)
    .fetch_one(&mut **tx)
    .await?;

    sqlx::query(
        "DELETE FROM lrr_tank_to_archive_map WHERE tankid = $1 AND arcid = $2",
    )
    .bind(tankid)
    .bind(arcid)
    .execute(&mut **tx)
    .await?;

    // Compact positions: shift everything after the removed slot down by 1.
    sqlx::query(
        "UPDATE lrr_tank_to_archive_map SET position = position - 1 WHERE tankid = $1 AND position > $2",
    )
    .bind(tankid)
    .bind(pos)
    .execute(&mut **tx)
    .await?;

    Ok(())
}
/// Replace the full ordered archive list for a tankoubon.
pub async fn replace_archives(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    tankid: &str,
    arcids: &[String],
) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM lrr_tank_to_archive_map WHERE tankid = $1")
        .bind(tankid)
        .execute(&mut **tx)
        .await?;

    for (i, arcid) in arcids.iter().enumerate() {
        let position = i32::try_from(i + 1)
            .map_err(|_| sqlx::Error::Protocol("archive list position overflows i32".into()))?;
        sqlx::query(
            "INSERT INTO lrr_tank_to_archive_map (tankid, arcid, position, update_date) VALUES ($1, $2, $3, CURRENT_DATE)",
        )
        .bind(tankid)
        .bind(arcid)
        .bind(position)
        .execute(&mut **tx)
        .await?;
    }

    Ok(())
}

/// Update reading progress for a tankoubon (global page + timestamp).
pub async fn update_progress<'e, E>(
    executor: E,
    tankid: &str,
    page: i32,
    lastreadtime: i64,
) -> Result<(), sqlx::Error>
where
    E: sqlx::PgExecutor<'e>,
{
    sqlx::query(
        "UPDATE lrr_tank SET progress = $1, lastreadtime = $2 WHERE tankid = $3",
    )
    .bind(page)
    .bind(lastreadtime)
    .bind(tankid)
    .execute(executor)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    /// Verify the position compaction arithmetic used by `remove_archive`.
    /// Pure logic: if an archive at position 3 is removed from a 5-element list,
    /// all positions > 3 should shift down by 1.
    #[test]
    fn position_compaction_logic() {
        // Mirrors the SQL sequence in remove_archive:
        //   1. SELECT position for the target row (removed = 3).
        //   2. DELETE the row at that position.
        //   3. UPDATE position = position - 1 WHERE position > removed.
        let mut positions = vec![1i32, 2, 3, 4, 5];
        let removed = 3i32;
        // Step 2: DELETE the row whose position == removed.
        positions.retain(|&p| p != removed);
        assert_eq!(positions, vec![1, 2, 4, 5]);
        // Step 3: shift rows with position > removed down by 1.
        for p in positions.iter_mut() {
            if *p > removed {
                *p -= 1;
            }
        }
        assert_eq!(positions, vec![1, 2, 3, 4]);
    }

    /// Verify that the max-position-plus-one insertion logic produces
    /// contiguous positions.
    #[test]
    fn append_position_logic() {
        let mut positions: Vec<i32> = vec![1, 2, 3];
        let next = positions.iter().max().copied().unwrap_or(0) + 1;
        positions.push(next);
        assert_eq!(positions, vec![1, 2, 3, 4]);
    }
}
