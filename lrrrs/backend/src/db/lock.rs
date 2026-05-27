// Transaction-scoped advisory locks. Released automatically on tx commit/rollback.

use sqlx::PgConnection;

pub async fn lock_archive_write(conn: &mut PgConnection, arcid: &str) -> Result<(), sqlx::Error> {
    // hashtext() is 32-bit; distinct keys can alias under extreme cardinality, causing false serialization.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)")
        .bind(format!("archive-write:{arcid}"))
        .execute(conn)
        .await?;
    Ok(())
}

pub async fn lock_category_write(conn: &mut PgConnection, catid: &str) -> Result<(), sqlx::Error> {
    // hashtext() is 32-bit; distinct keys can alias under extreme cardinality, causing false serialization.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)")
        .bind(format!("category-write:{catid}"))
        .execute(conn)
        .await?;
    Ok(())
}

pub async fn lock_category_create(conn: &mut PgConnection) -> Result<(), sqlx::Error> {
    // hashtext() is 32-bit; distinct keys can alias under extreme cardinality, causing false serialization.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)")
        .bind("category-create")
        .execute(conn)
        .await?;
    Ok(())
}

pub async fn lock_first_install(conn: &mut PgConnection) -> Result<(), sqlx::Error> {
    // Serializes concurrent first-boot SELECT+INSERT on lrr_category so only one
    // process creates the Favorites category and bookmark link.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext('first_install')::bigint)")
        .execute(conn)
        .await?;
    Ok(())
}
