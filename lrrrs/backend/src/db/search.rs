//! Search SQL queries.
//!
//! All public functions accept a `sqlx::PgExecutor` (satisfied by both
//! `&PgPool` and `&mut PgConnection`) so callers can share a single connection
//! across related queries to avoid named-prepared-statement ID collisions that
//! arise when multiple pool checkouts interleave on the same connection slot.
//! Business logic lives in `service::search`.

use std::collections::HashMap;

use crate::openapi::types::{ArchiveMetadataJson, ArchiveMetadataJsonArcid, ArchiveMetadataJsonIsnew};
use crate::support::search_filter::SearchToken;

/// Category row: distinguishes static vs dynamic category.
#[derive(sqlx::FromRow)]
pub struct CategoryRow {
    pub catid: String,
    /// Non-null and non-empty: dynamic category (treat as extra filter tokens).
    pub search: Option<String>,
}

/// Fetch a single category by ID.
pub async fn get_category(conn: &mut sqlx::PgConnection, catid: &str) -> Result<Option<CategoryRow>, sqlx::Error> {
    sqlx::query_as::<_, CategoryRow>(
        "SELECT catid, search FROM lrr_category WHERE catid = $1",
    )
    .bind(catid)
    .fetch_optional(&mut *conn)
    .await
}

/// Full archive row returned by search queries (shares projection with `db::archive`).
#[derive(sqlx::FromRow)]
pub struct SearchArchiveRow {
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

impl SearchArchiveRow {
    pub fn into_dto(self) -> ArchiveMetadataJson {
        let title = if self.title.trim().is_empty() {
            self.filename.clone()
        } else {
            self.title
        };
        let arcid = ArchiveMetadataJsonArcid::try_from(self.arcid)
            .expect("lrr_archive.arcid violates the arcid pattern; database is corrupt");
        ArchiveMetadataJson {
            arcid,
            title,
            filename: self.filename,
            tags: self.tags,
            summary: self.summary,
            isnew: if self.isnew {
                ArchiveMetadataJsonIsnew::True
            } else {
                ArchiveMetadataJsonIsnew::False
            },
            extension: self.extension.unwrap_or_default(),
            progress: i64::from(self.progress),
            pagecount: i64::from(self.pagecount),
            lastreadtime: self.lastreadtime,
            size: self.arcsize.unwrap_or(0),
            toc: Vec::new(),
        }
    }
}

/// Total (unfiltered) archive/tank count.
pub async fn total_count(conn: &mut sqlx::PgConnection, grouptanks: bool) -> Result<i64, sqlx::Error> {
    if grouptanks {
        // Standalone archives + tank count
        let arc_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM lrr_archive \
             WHERE NOT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE arcid = lrr_archive.arcid)"
        )
        .fetch_one(&mut *conn)
        .await?;

        let tank_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM lrr_tank")
            .fetch_one(&mut *conn)
            .await?;

        Ok(arc_count + tank_count)
    } else {
        sqlx::query_scalar("SELECT COUNT(*) FROM lrr_archive")
            .fetch_one(&mut *conn)
            .await
    }
}

/// Sort specifier for archive search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SortBy {
    Title,
    LastRead,
    /// Namespace tag sort. Must be a valid alphanumeric/underscore/hyphen string.
    TagNamespace(String),
}

impl SortBy {
    /// Default sort direction when the client supplies no `order` parameter.
    ///
    /// Mirrors Perl LRR: `lastread` defaults to most-recently-read first (DESC);
    /// `title` and tag-namespace sorts default to A→Z (ASC).
    pub fn default_desc(&self) -> bool {
        matches!(self, SortBy::LastRead)
    }
}

/// Parameters for a search query.
pub struct SearchParams<'a> {
    pub tokens: &'a [SearchToken],
    pub category_id: Option<&'a str>,
    /// None: static category checked; Some(tokens): merged into token list
    pub extra_tokens: &'a [SearchToken],
    pub sortby: SortBy,
    pub sort_desc: bool,
    pub newonly: bool,
    pub untaggedonly: bool,
    pub grouptanks: bool,
    pub hidecompleted: bool,
    /// None means fetch all (no pagination).
    pub start: Option<i64>,
    pub keysperpage: Option<i64>,
}

/// Result of a search query.
pub struct SearchResult {
    pub filtered: i64,
    pub records: Vec<SearchArchiveRow>,
}

/// Perform the main archive search.
///
/// Returns filtered count and paginated (or full) archive rows.
pub async fn search_archives(conn: &mut sqlx::PgConnection, params: &SearchParams<'_>) -> Result<SearchResult, sqlx::Error> {
    // Merge user tokens + dynamic-category extra tokens
    let all_tokens: Vec<&SearchToken> = params
        .tokens
        .iter()
        .chain(params.extra_tokens.iter())
        .collect();

    let mut bind_values: Vec<String> = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();
    let mut main_idx: u32 = 1;

    // Tag-namespace sort needs a LEFT JOIN subquery with one bind param (the namespace).
    // That param is always $1 when present.
    let lateral_ns_value: Option<String> = match &params.sortby {
        SortBy::TagNamespace(ns)
            if ns.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') =>
        {
            bind_values.push(ns.clone());
            main_idx += 1;
            Some(ns.clone())
        }
        _ => None,
    };

    let mut sql = String::from(
        "SELECT a.arcid, a.filename, a.title, a.summary, a.isnew, a.progress, \
         a.pagecount, a.lastreadtime, a.arcsize, a.extension, \
         COALESCE(string_agg(CASE WHEN t.namespace = '' THEN t.value ELSE t.namespace || ':' || t.value END, ', '), '') AS tags, \
         COUNT(*) OVER() AS filtered_total \
         FROM lrr_archive a \
         LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid \
         LEFT JOIN lrr_tag t ON atm.tagid = t.tagid",
    );

    if lateral_ns_value.is_some() {
        // lateral param is always at $1
        sql.push_str(
            " LEFT JOIN (SELECT atm2.arcid, MAX(atm2.value) AS sort_value \
              FROM lrr_archive_to_tag_map atm2 WHERE atm2.namespace = $1 GROUP BY atm2.arcid) \
              sort_tag ON sort_tag.arcid = a.arcid",
        );
    }

    // grouptanks: exclude archives that are tank members
    if params.grouptanks {
        where_parts.push("NOT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE arcid = a.arcid)".to_string());
    }

    // Static category membership filter
    if let Some(catid) = params.category_id {
        where_parts.push(format!(
            "EXISTS (SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ${} AND arcid = a.arcid)",
            main_idx
        ));
        bind_values.push(catid.to_string());
        main_idx += 1;
    }

    if params.newonly {
        where_parts.push("a.isnew = TRUE".to_string());
    }

    if params.hidecompleted {
        where_parts.push("NOT (a.pagecount > 0 AND a.progress::float / a.pagecount > 0.85)".to_string());
    }

    if params.untaggedonly {
        // Excludes basic metadata namespaces; mirrors PgSearch.pm::do_search
        where_parts.push(
            "NOT EXISTS (\
                SELECT 1 FROM lrr_archive_to_tag_map atm_u \
                WHERE atm_u.arcid = a.arcid \
                AND atm_u.namespace NOT IN ('artist','parody','series','language','event','group','date_added','timestamp','source')\
            )".to_string(),
        );
    }

    for token in &all_tokens {
        let tag = &token.tag;
        let isneg = token.isneg;
        let isexact = token.isexact;

        // pages: / read: range predicates
        if let Some(range_clause) = try_build_range_clause(tag, &mut main_idx) {
            let (clause, value) = range_clause;
            let clause = if isneg { format!("NOT ({clause})") } else { clause };
            where_parts.push(clause);
            bind_values.push(value);
            continue;
        }

        // Tag-based predicates
        let clause = build_tag_clause(tag, isneg, isexact, &mut main_idx, &mut bind_values);
        where_parts.push(clause);
    }

    if !where_parts.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&where_parts.join(" AND "));
    }

    // GROUP BY required because of the string_agg + COUNT OVER
    sql.push_str(" GROUP BY a.arcid, a.filename, a.title, a.summary, a.isnew, a.progress, a.pagecount, a.lastreadtime, a.arcsize, a.extension");

    if matches!(params.sortby, SortBy::TagNamespace(_)) && lateral_ns_value.is_some() {
        sql.push_str(", sort_tag.sort_value");
    }

    // ORDER BY (direction already resolved upstream; see service::search::resolve_sort_desc)
    sql.push_str(&build_order_by(&params.sortby, params.sort_desc, lateral_ns_value.is_some()));

    // LIMIT / OFFSET
    let mut limit_value: Option<i64> = None;
    let mut offset_value: Option<i64> = None;
    if let (Some(start), Some(kpp)) = (params.start, params.keysperpage) {
        if kpp > 0 {
            sql.push_str(&format!(" LIMIT ${} OFFSET ${}", main_idx, main_idx + 1));
            limit_value = Some(kpp);
            offset_value = Some(start);
        }
    }

    // Runtime-constructed SQL requires query_as() instead of query_as!(). Use
    // named prepared statements (persistent default) to avoid bind-count mismatches
    // from the shared unnamed statement slot when SQL shape varies across requests.
    let mut q = sqlx::query_as::<_, SearchRowWithTotal>(sqlx::AssertSqlSafe(sql));

    for v in &bind_values {
        q = q.bind(v.as_str());
    }
    if let Some(limit) = limit_value {
        q = q.bind(limit);
    }
    if let Some(offset) = offset_value {
        q = q.bind(offset);
    }

    let rows: Vec<SearchRowWithTotal> = q.fetch_all(&mut *conn).await?;

    let filtered = rows.first().map(|r| r.filtered_total).unwrap_or(0);

    // When OFFSET exceeds result count, the window function returns 0 rows and
    // filtered_total is unavailable. Fall back to COUNT(*) in this edge case only.
    let filtered = if filtered == 0 && rows.is_empty() && params.start.is_some() {
        // Rebuild WHERE with fresh $1..$N numbering (no lateral param, no LIMIT/OFFSET).
        // LIMIT/OFFSET are bound directly on the query, not stored in bind_values.
        let where_bind_start = if lateral_ns_value.is_some() { 1 } else { 0 };
        let where_values = &bind_values[where_bind_start..];
        let count_where = renumber_where_clauses(&where_parts, 1);
        let mut count_sql = String::from("SELECT COUNT(*) FROM lrr_archive a");
        if !count_where.is_empty() {
            count_sql.push_str(" WHERE ");
            count_sql.push_str(&count_where);
        }
        let mut count_q = sqlx::query_scalar::<_, i64>(sqlx::AssertSqlSafe(count_sql));
        for v in where_values {
            count_q = count_q.bind(v.as_str());
        }
        count_q.fetch_one(&mut *conn).await?
    } else {
        filtered
    };

    let records: Vec<SearchArchiveRow> = rows.into_iter().map(|r| SearchArchiveRow {
        arcid: r.arcid,
        filename: r.filename,
        title: r.title,
        summary: r.summary,
        isnew: r.isnew,
        progress: r.progress,
        pagecount: r.pagecount,
        lastreadtime: r.lastreadtime,
        arcsize: r.arcsize,
        extension: r.extension,
        tags: r.tags,
    }).collect();

    Ok(SearchResult { filtered, records })
}

// Combined row from the windowed outer query.
#[derive(sqlx::FromRow)]
struct SearchRowWithTotal {
    arcid: String,
    filename: String,
    title: String,
    summary: Option<String>,
    isnew: bool,
    progress: i32,
    pagecount: i32,
    lastreadtime: i64,
    arcsize: Option<i64>,
    extension: Option<String>,
    tags: String,
    filtered_total: i64,
}

// IDs-only row for random archive sampling.
#[derive(sqlx::FromRow)]
struct SearchArcidRow {
    arcid: String,
}

/// Perform an unpaginated search returning only arcids (no tag aggregation).
///
/// Used by `service::search::search_random_archives` to avoid materialising
/// full DTOs for the entire matching set before sampling.
pub async fn search_archive_ids_only(
    conn: &mut sqlx::PgConnection,
    params: &SearchParams<'_>,
) -> Result<Vec<String>, sqlx::Error> {
    // Merge user tokens + dynamic-category extra tokens
    let all_tokens: Vec<&SearchToken> = params
        .tokens
        .iter()
        .chain(params.extra_tokens.iter())
        .collect();

    let mut bind_values: Vec<String> = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();
    let mut main_idx: u32 = 1;

    let mut sql = String::from("SELECT a.arcid FROM lrr_archive a");

    if params.grouptanks {
        where_parts.push(
            "NOT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE arcid = a.arcid)"
                .to_string(),
        );
    }

    if let Some(catid) = params.category_id {
        where_parts.push(format!(
            "EXISTS (SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ${} AND arcid = a.arcid)",
            main_idx
        ));
        bind_values.push(catid.to_string());
        main_idx += 1;
    }

    if params.newonly {
        where_parts.push("a.isnew = TRUE".to_string());
    }

    if params.hidecompleted {
        where_parts
            .push("NOT (a.pagecount > 0 AND a.progress::float / a.pagecount > 0.85)".to_string());
    }

    if params.untaggedonly {
        where_parts.push(
            "NOT EXISTS (\
                SELECT 1 FROM lrr_archive_to_tag_map atm_u \
                WHERE atm_u.arcid = a.arcid \
                AND atm_u.namespace NOT IN ('artist','parody','series','language','event','group','date_added','timestamp','source')\
            )"
            .to_string(),
        );
    }

    for token in &all_tokens {
        let tag = &token.tag;
        let isneg = token.isneg;
        let isexact = token.isexact;

        if let Some(range_clause) = try_build_range_clause(tag, &mut main_idx) {
            let (clause, value) = range_clause;
            let clause = if isneg { format!("NOT ({clause})") } else { clause };
            where_parts.push(clause);
            bind_values.push(value);
            continue;
        }

        let clause = build_tag_clause(tag, isneg, isexact, &mut main_idx, &mut bind_values);
        where_parts.push(clause);
    }

    if !where_parts.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&where_parts.join(" AND "));
    }

    let mut q = sqlx::query_as::<_, SearchArcidRow>(sqlx::AssertSqlSafe(sql));
    for v in &bind_values {
        q = q.bind(v.as_str());
    }
    let rows: Vec<SearchArcidRow> = q.fetch_all(&mut *conn).await?;
    Ok(rows.into_iter().map(|r| r.arcid).collect())
}

/// Tank row returned by tank search queries.
#[derive(sqlx::FromRow)]
pub struct SearchTankRow {
    pub tankid: String,
    pub filtered_total: i64,
}

/// Perform the tank search (when grouptanks=true).
///
/// Returns (filtered_count, tank_ids). Tank IDs are prepended to archive IDs by the service.
pub async fn search_tanks(
    conn: &mut sqlx::PgConnection,
    tokens: &[SearchToken],
    extra_tokens: &[SearchToken],
    category_id: Option<&str>,
    sortby: &SortBy,
    sort_desc: bool,
    start: Option<i64>,
    keysperpage: Option<i64>,
) -> Result<(i64, Vec<String>), sqlx::Error> {
    let all_tokens: Vec<&SearchToken> = tokens.iter().chain(extra_tokens.iter()).collect();

    let mut sql = String::from(
        "SELECT t.tankid, COUNT(*) OVER() AS filtered_total FROM lrr_tank t",
    );

    let mut where_parts: Vec<String> = Vec::new();
    let mut bind_values: Vec<String> = Vec::new();
    let mut main_idx: u32 = 1;

    // Category filter for tanks
    if let Some(catid) = category_id {
        where_parts.push(format!(
            "EXISTS (SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ${} AND arcid = t.tankid)",
            main_idx
        ));
        bind_values.push(catid.to_string());
        main_idx += 1;
    }

    for token in &all_tokens {
        let tag = &token.tag;
        let isneg = token.isneg;
        let isexact = token.isexact;

        // Skip pages:/read: for tanks; they don't have pagecount/progress
        if tag.starts_with("read:") || tag.starts_with("pages:") {
            continue;
        }

        let clause = build_tank_tag_clause(tag, isneg, isexact, &mut main_idx, &mut bind_values);
        where_parts.push(clause);
    }

    if !where_parts.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&where_parts.join(" AND "));
    }

    // ORDER BY (tanks only sort by name; no tag-namespace sort available)
    let dir = if sort_desc { "DESC" } else { "ASC" };
    match sortby {
        SortBy::Title | SortBy::LastRead | SortBy::TagNamespace(_) => {
            sql.push_str(&format!(" ORDER BY t.name {dir}"));
        }
    }

    // LIMIT / OFFSET
    let mut limit_value: Option<i64> = None;
    let mut offset_value: Option<i64> = None;
    if let (Some(start), Some(kpp)) = (start, keysperpage) {
        if kpp > 0 {
            sql.push_str(&format!(" LIMIT ${} OFFSET ${}", main_idx, main_idx + 1));
            limit_value = Some(kpp);
            offset_value = Some(start);
        }
    }

    let mut q = sqlx::query_as::<_, SearchTankRow>(sqlx::AssertSqlSafe(sql));
    for v in &bind_values {
        q = q.bind(v.as_str());
    }
    if let Some(limit) = limit_value {
        q = q.bind(limit);
    }
    if let Some(offset) = offset_value {
        q = q.bind(offset);
    }

    let rows: Vec<SearchTankRow> = q.fetch_all(&mut *conn).await?;
    let filtered = rows.first().map(|r| r.filtered_total).unwrap_or(0);
    let ids: Vec<String> = rows.into_iter().map(|r| r.tankid).collect();

    Ok((filtered, ids))
}

// Tank row fetched for DTO conversion.
#[derive(sqlx::FromRow)]
struct TankRow {
    tankid: String,
    name: String,
    summary: Option<String>,
    tags: Option<String>,
}

/// Fetch tank rows by IDs and convert to `ArchiveMetadataJson` representations.
/// Tanks use their tankid as arcid and name as title (standard upstream convention).
pub async fn fetch_tank_dtos(conn: &mut sqlx::PgConnection, tank_ids: &[String]) -> Result<Vec<ArchiveMetadataJson>, sqlx::Error> {
    if tank_ids.is_empty() {
        return Ok(Vec::new());
    }
    let placeholders: Vec<String> = (1..=tank_ids.len()).map(|i| format!("${i}")).collect();
    let sql = format!(
        "SELECT tankid, name, summary, tags FROM lrr_tank WHERE tankid IN ({})",
        placeholders.join(", ")
    );
    let mut q = sqlx::query_as::<_, TankRow>(sqlx::AssertSqlSafe(sql));
    for id in tank_ids {
        q = q.bind(id.as_str());
    }
    let rows: Vec<TankRow> = q.fetch_all(&mut *conn).await?;

    // Preserve tank_ids order
    let mut id_to_row: HashMap<String, TankRow> = rows.into_iter().map(|r| (r.tankid.clone(), r)).collect();
    let dtos: Vec<ArchiveMetadataJson> = tank_ids
        .iter()
        .filter_map(|id| id_to_row.remove(id))
        .map(tank_row_into_dto)
        .collect();

    Ok(dtos)
}

/// Fetch full archive DTOs for a given list of arcids, preserving input order.
///
/// Used by `service::search::search_random_archives` to hydrate only the
/// sampled subset after the ids-only pass.
pub async fn fetch_archives_by_ids(
    conn: &mut sqlx::PgConnection,
    arc_ids: &[String],
) -> Result<Vec<ArchiveMetadataJson>, sqlx::Error> {
    if arc_ids.is_empty() {
        return Ok(Vec::new());
    }
    let placeholders: Vec<String> = (1..=arc_ids.len()).map(|i| format!("${i}")).collect();
    let sql = format!(
        "SELECT a.arcid, a.filename, a.title, a.summary, a.isnew, a.progress, \
         a.pagecount, a.lastreadtime, a.arcsize, a.extension, \
         COALESCE(string_agg(CASE WHEN t.namespace = '' THEN t.value ELSE t.namespace || ':' || t.value END, ', '), '') AS tags \
         FROM lrr_archive a \
         LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid \
         LEFT JOIN lrr_tag t ON atm.tagid = t.tagid \
         WHERE a.arcid IN ({}) \
         GROUP BY a.arcid, a.filename, a.title, a.summary, a.isnew, a.progress, \
         a.pagecount, a.lastreadtime, a.arcsize, a.extension",
        placeholders.join(", ")
    );
    // AssertSqlSafe rationale: placeholders are integer-indexed positional parameters only.
    let mut q = sqlx::query_as::<_, SearchArchiveRow>(sqlx::AssertSqlSafe(sql));
    for id in arc_ids {
        q = q.bind(id.as_str());
    }
    let rows: Vec<SearchArchiveRow> = q.fetch_all(&mut *conn).await?;

    // Preserve arc_ids order
    let mut id_to_row: HashMap<String, SearchArchiveRow> =
        rows.into_iter().map(|r| (r.arcid.clone(), r)).collect();
    let dtos: Vec<ArchiveMetadataJson> = arc_ids
        .iter()
        .filter_map(|id| id_to_row.remove(id))
        .map(SearchArchiveRow::into_dto)
        .collect();

    Ok(dtos)
}

fn tank_row_into_dto(r: TankRow) -> ArchiveMetadataJson {
    let arcid = ArchiveMetadataJsonArcid::try_from(r.tankid.clone())
        .expect("lrr_tank.tankid violates the arcid pattern; database is corrupt");
    ArchiveMetadataJson {
        arcid,
        title: r.name.clone(),
        filename: r.name,
        tags: r.tags.unwrap_or_default(),
        summary: r.summary,
        isnew: ArchiveMetadataJsonIsnew::False,
        extension: String::new(),
        progress: 0,
        pagecount: 0,
        lastreadtime: 0,
        size: 0,
        toc: Vec::new(),
    }
}

// Remaps $N placeholders to a fresh sequence; repeated occurrences of the same
// original $N map to the same new $M to preserve single-bind semantics.
fn renumber_where_clauses(parts: &[String], start_idx: u32) -> String {
    use std::collections::HashMap;
    let joined = parts.join(" AND ");
    let mut out = String::with_capacity(joined.len() + 16);
    let bytes = joined.as_bytes();
    let mut i = 0;
    let mut next_idx = start_idx;
    let mut mapping: HashMap<u32, u32> = HashMap::new();
    while i < bytes.len() {
        if bytes[i] == b'$' {
            let mut j = i + 1;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            if j > i + 1 {
                let old_n: u32 = joined[i + 1..j].parse().unwrap_or(0);
                let new_n = *mapping.entry(old_n).or_insert_with(|| {
                    let n = next_idx;
                    next_idx += 1;
                    n
                });
                out.push('$');
                out.push_str(&new_n.to_string());
                i = j;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

fn try_build_range_clause(tag: &str, main_idx: &mut u32) -> Option<(String, String)> {
    // Pattern: (read|pages):(>|<|>=|<=)?(\d+)
    let (col_raw, rest) = if let Some(rest) = tag.strip_prefix("read:") {
        ("read", rest)
    } else if let Some(rest) = tag.strip_prefix("pages:") {
        ("pages", rest)
    } else {
        return None;
    };

    let col = if col_raw == "pages" { "pagecount" } else { "progress" };

    let (op, num_str) = if let Some(r) = rest.strip_prefix(">=") {
        (">=", r)
    } else if let Some(r) = rest.strip_prefix("<=") {
        ("<=", r)
    } else if let Some(r) = rest.strip_prefix('>') {
        (">", r)
    } else if let Some(r) = rest.strip_prefix('<') {
        ("<", r)
    } else {
        ("=", rest)
    };

    // Validate that num_str is all digits
    if num_str.is_empty() || !num_str.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }

    // Cast parameter to integer: all bind values are bound as text (via bind_values: Vec<String>),
    // but pagecount/progress are integer columns. PostgreSQL rejects integer = text without cast.
    let clause = format!("a.{col} {op} ${main_idx}::integer");
    *main_idx += 1;
    Some((clause, num_str.to_string()))
}
fn build_tag_clause(
    tag: &str,
    isneg: bool,
    isexact: bool,
    main_idx: &mut u32,
    bind_values: &mut Vec<String>,
) -> String {
    // Bare 40-hex-char token: direct arcid equality (matches PgSearch.pm::search_postgres_with_dbh).
    // Checked before namespace splitting and wildcard conversion.
    if tag.len() == 40 && tag.chars().all(|c| c.is_ascii_hexdigit()) {
        let clause = if isneg {
            format!("a.arcid != ${main_idx}")
        } else {
            format!("a.arcid = ${main_idx}")
        };
        bind_values.push(tag.to_lowercase());
        *main_idx += 1;
        return clause;
    }

    // Parse namespace:value
    let (namespace, value) = split_namespace(tag);

    // Convert LRR wildcards to SQL LIKE patterns
    let (ns_pat, val_pat) = convert_wildcards(namespace, value);

    let clause = if isexact {
        build_exact_archive_clause(&ns_pat, &val_pat, main_idx, bind_values)
    } else {
        build_fuzzy_archive_clause(&ns_pat, &val_pat, main_idx, bind_values)
    };

    if isneg {
        format!("NOT ({clause})")
    } else {
        clause
    }
}

fn build_tank_tag_clause(
    tag: &str,
    isneg: bool,
    isexact: bool,
    main_idx: &mut u32,
    bind_values: &mut Vec<String>,
) -> String {
    let (namespace, value) = split_namespace(tag);
    let (ns_pat, val_pat) = convert_wildcards(namespace, value);

    let clause = if isexact {
        build_exact_tank_clause(&ns_pat, &val_pat, main_idx, bind_values)
    } else {
        build_fuzzy_tank_clause(&ns_pat, &val_pat, main_idx, bind_values)
    };

    if isneg {
        format!("NOT ({clause})")
    } else {
        clause
    }
}

fn split_namespace(tag: &str) -> (Option<&str>, &str) {
    if let Some(pos) = tag.find(':') {
        let ns = &tag[..pos];
        let val = &tag[pos + 1..];
        (Some(ns), val)
    } else {
        (None, tag)
    }
}

fn convert_wildcards<'a>(
    namespace: Option<&'a str>,
    value: &'a str,
) -> (Option<String>, String) {
    let ns = namespace.map(|n| n.replace('?', "_").replace('*', "%"));
    let val = value.replace('?', "_").replace('*', "%");
    (ns, val)
}

/// Build the archive `ORDER BY` clause. `keyed` is true when the tag-namespace
/// sort LEFT JOIN (`sort_tag`) is present. `sort_desc` is the already-resolved
/// direction; default resolution lives in `service::search::resolve_sort_desc`.
fn build_order_by(sortby: &SortBy, sort_desc: bool, keyed: bool) -> String {
    let dir = if sort_desc { "DESC" } else { "ASC" };
    match sortby {
        SortBy::Title => format!(" ORDER BY a.title {dir}"),
        SortBy::LastRead => format!(
            " ORDER BY CASE WHEN a.lastreadtime IS NULL OR a.lastreadtime = 0 THEN 1 ELSE 0 END, a.lastreadtime {dir}"
        ),
        SortBy::TagNamespace(_) if keyed => format!(
            " ORDER BY CASE WHEN sort_tag.sort_value IS NULL THEN 1 ELSE 0 END, sort_tag.sort_value {dir}, a.title ASC"
        ),
        // Invalid/absent sort namespace falls back to title.
        SortBy::TagNamespace(_) => format!(" ORDER BY a.title {dir}"),
    }
}

/// LIKE/ILIKE pattern for a `namespace:value` match against the comma-joined
/// `lrr_tank.tags` string. The `:` separator is always present so a namespaced
/// query cannot match across namespace boundaries; an empty `value` matches any
/// value in the namespace.
fn tank_tag_pattern(ns: &str, value: &str) -> String {
    format!("%{ns}:{value}%")
}

fn build_exact_archive_clause(
    namespace: &Option<String>,
    value: &str,
    main_idx: &mut u32,
    bind_values: &mut Vec<String>,
) -> String {
    match namespace {
        Some(ns) if value.is_empty() => {
            // namespace-only: search for ANY tag with this namespace
            let clause = format!(
                "EXISTS (SELECT 1 FROM lrr_archive_to_tag_map atm \
                 JOIN lrr_tag t ON atm.tagid = t.tagid \
                 WHERE atm.arcid = a.arcid AND LOWER(t.namespace) = ${})",
                main_idx
            );
            bind_values.push(ns.clone());
            *main_idx += 1;
            clause
        }
        Some(ns) => {
            // namespace:value exact match
            let clause = format!(
                "EXISTS (SELECT 1 FROM lrr_archive_to_tag_map atm \
                 JOIN lrr_tag t ON atm.tagid = t.tagid \
                 WHERE atm.arcid = a.arcid AND LOWER(t.namespace) = ${} AND LOWER(t.value) = ${})",
                *main_idx,
                *main_idx + 1
            );
            bind_values.push(ns.clone());
            bind_values.push(value.to_string());
            *main_idx += 2;
            clause
        }
        None => {
            // No namespace: exact match on title or tag value
            if value.contains('%') || value.contains('_') {
                // Wildcards present: use ILIKE
                let clause = format!(
                    "(a.title ILIKE ${p} OR EXISTS (\
                     SELECT 1 FROM lrr_archive_to_tag_map atm \
                     JOIN lrr_tag t ON atm.tagid = t.tagid \
                     WHERE atm.arcid = a.arcid AND t.value ILIKE ${p}))",
                    p = main_idx
                );
                bind_values.push(value.to_string());
                *main_idx += 1;
                clause
            } else {
                // No wildcards: case-insensitive equality
                let clause = format!(
                    "(LOWER(a.title) = ${p} OR EXISTS (\
                     SELECT 1 FROM lrr_archive_to_tag_map atm \
                     JOIN lrr_tag t ON atm.tagid = t.tagid \
                     WHERE atm.arcid = a.arcid AND LOWER(t.value) = ${p}))",
                    p = main_idx
                );
                bind_values.push(value.to_string());
                *main_idx += 1;
                clause
            }
        }
    }
}

fn build_fuzzy_archive_clause(
    namespace: &Option<String>,
    value: &str,
    main_idx: &mut u32,
    bind_values: &mut Vec<String>,
) -> String {
    match namespace {
        Some(ns) if value.is_empty() => {
            // namespace-only partial match
            let clause = format!(
                "EXISTS (SELECT 1 FROM lrr_archive_to_tag_map atm \
                 JOIN lrr_tag t ON atm.tagid = t.tagid \
                 WHERE atm.arcid = a.arcid AND t.namespace ILIKE ${})",
                main_idx
            );
            bind_values.push(ns.clone());
            *main_idx += 1;
            clause
        }
        Some(ns) => {
            // namespace (exact unless wildcards) + value fuzzy
            let clause = format!(
                "EXISTS (SELECT 1 FROM lrr_archive_to_tag_map atm \
                 JOIN lrr_tag t ON atm.tagid = t.tagid \
                 WHERE atm.arcid = a.arcid AND t.namespace ILIKE ${} AND t.value ILIKE ${})",
                *main_idx,
                *main_idx + 1
            );
            bind_values.push(ns.clone());
            bind_values.push(format!("%{value}%"));
            *main_idx += 2;
            clause
        }
        None => {
            // No namespace: check for wildcards already in value
            if value.contains('%') || value.contains('_') {
                // Wildcard search: ILIKE on title, arcid, namespace, value
                let p = *main_idx;
                let clause = format!(
                    "(a.title ILIKE ${p} OR a.arcid ILIKE ${p} OR EXISTS (\
                     SELECT 1 FROM lrr_archive_to_tag_map atm \
                     JOIN lrr_tag t ON atm.tagid = t.tagid \
                     WHERE atm.arcid = a.arcid AND (t.namespace ILIKE ${p} OR t.value ILIKE ${p})))"
                );
                bind_values.push(format!("%{value}%"));
                *main_idx += 1;
                clause
            } else {
                // Simple word search: ILIKE substring on title, namespace, value
                let p = *main_idx;
                let clause = format!(
                    "(a.title ILIKE ${p} OR EXISTS (\
                     SELECT 1 FROM lrr_archive_to_tag_map atm \
                     JOIN lrr_tag t ON atm.tagid = t.tagid \
                     WHERE atm.arcid = a.arcid AND (t.namespace ILIKE ${p} OR t.value ILIKE ${p})))"
                );
                bind_values.push(format!("%{value}%"));
                *main_idx += 1;
                clause
            }
        }
    }
}

fn build_exact_tank_clause(
    namespace: &Option<String>,
    value: &str,
    main_idx: &mut u32,
    bind_values: &mut Vec<String>,
) -> String {
    match namespace {
        Some(ns) if value.is_empty() => {
            let clause = format!("t.tags LIKE ${}", main_idx);
            bind_values.push(tank_tag_pattern(ns, ""));
            *main_idx += 1;
            clause
        }
        Some(ns) => {
            let clause = format!("t.tags LIKE ${}", main_idx);
            bind_values.push(tank_tag_pattern(ns, value));
            *main_idx += 1;
            clause
        }
        None => {
            let clause = format!("(t.name = ${p} OR t.tags LIKE ${p})", p = main_idx);
            bind_values.push(value.to_string());
            *main_idx += 1;
            clause
        }
    }
}

fn build_fuzzy_tank_clause(
    namespace: &Option<String>,
    value: &str,
    main_idx: &mut u32,
    bind_values: &mut Vec<String>,
) -> String {
    match namespace {
        Some(ns) if value.is_empty() => {
            let clause = format!("t.tags ILIKE ${}", main_idx);
            bind_values.push(tank_tag_pattern(ns, ""));
            *main_idx += 1;
            clause
        }
        Some(ns) => {
            let clause = format!("t.tags ILIKE ${}", main_idx);
            bind_values.push(tank_tag_pattern(ns, value));
            *main_idx += 1;
            clause
        }
        None => {
            let p = *main_idx;
            let clause = format!(
                "(t.tankid ILIKE ${p} OR t.name ILIKE ${p} OR t.summary ILIKE ${p} OR t.tags ILIKE ${p})"
            );
            bind_values.push(format!("%{value}%"));
            *main_idx += 1;
            clause
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lastread_defaults_to_descending() {
        assert!(SortBy::LastRead.default_desc());
        assert!(!SortBy::Title.default_desc());
        assert!(!SortBy::TagNamespace("artist".to_string()).default_desc());
    }

    #[test]
    fn order_by_title_honours_direction() {
        assert_eq!(build_order_by(&SortBy::Title, false, false), " ORDER BY a.title ASC");
        assert_eq!(build_order_by(&SortBy::Title, true, false), " ORDER BY a.title DESC");
    }

    #[test]
    fn order_by_lastread_partitions_unread_then_applies_direction() {
        assert_eq!(
            build_order_by(&SortBy::LastRead, false, false),
            " ORDER BY CASE WHEN a.lastreadtime IS NULL OR a.lastreadtime = 0 THEN 1 ELSE 0 END, a.lastreadtime ASC"
        );
        assert!(build_order_by(&SortBy::LastRead, true, false).ends_with("a.lastreadtime DESC"));
    }

    #[test]
    fn tank_tag_pattern_anchors_the_namespace_colon() {
        assert_eq!(tank_tag_pattern("artist", "foo"), "%artist:foo%");
        assert_eq!(tank_tag_pattern("artist", ""), "%artist:%");
    }

    #[test]
    fn tank_clauses_share_the_colon_anchored_pattern() {
        let mut idx = 1;
        let mut binds = Vec::new();
        let _ = build_fuzzy_tank_clause(&Some("artist".to_string()), "foo", &mut idx, &mut binds);
        assert_eq!(binds, vec!["%artist:foo%".to_string()]);

        let mut idx2 = 1;
        let mut binds2 = Vec::new();
        let _ = build_exact_tank_clause(&Some("artist".to_string()), "foo", &mut idx2, &mut binds2);
        assert_eq!(binds2, vec!["%artist:foo%".to_string()]);
    }
}
