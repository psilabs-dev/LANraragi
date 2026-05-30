//! Search business logic.
//!
//! Orchestrates token parsing, category lookup, and delegates SQL execution
//! to `db::search`.

use std::sync::atomic::{AtomicU64, Ordering};

use sqlx::PgPool;
use tracing::warn;

use crate::db;
use crate::db::search::{SearchParams, SortBy};
use crate::openapi::types::ArchiveMetadataJson;
use crate::support::search_filter::compute_search_filter;

/// Parameters passed in from the controller for `searchArchiveIndex`.
pub struct SearchInput<'a> {
    pub filter: Option<&'a str>,
    pub category_id: Option<&'a str>,
    pub start: i64,
    pub sortby: Option<&'a str>,
    /// Raw `order` query param: `Some("desc")`, `Some("asc")`, or `None`
    /// (no param → field default via `SortBy::default_desc`).
    pub order: Option<&'a str>,
    pub newonly: bool,
    pub untaggedonly: bool,
    pub grouptanks: bool,
    pub hidecompleted: bool,
    /// Server-configured page size.
    pub pagesize: i64,
}

/// Result of a `search_archive_index` call.
pub struct SearchOutput {
    pub records_total: i64,
    pub records_filtered: i64,
    pub data: Vec<ArchiveMetadataJson>,
}

/// Perform a paginated/filtered archive search.
pub async fn search_archive_index(
    pool: &PgPool,
    input: &SearchInput<'_>,
) -> Result<SearchOutput, sqlx::Error> {
    let (total, filtered, data) = run_search(pool, input).await?;
    Ok(SearchOutput { records_total: total, records_filtered: filtered, data })
}

/// Pull a random sample from the search matching the given parameters.
pub async fn search_random_archives(
    pool: &PgPool,
    filter: Option<&str>,
    category_id: Option<&str>,
    newonly: bool,
    untaggedonly: bool,
    grouptanks: bool,
    hidecompleted: bool,
    count: usize,
) -> Result<Vec<ArchiveMetadataJson>, sqlx::Error> {
    // Fetch arcids only (no tag aggregation), shuffle, sample, then hydrate.
    // Mirrors Perl: do_search(..., start=-1) -> @ids -> sample -> get_archive_json_multi.
    let filter_str = filter.unwrap_or("");
    let tokens = compute_search_filter(filter_str);

    let mut conn = pool.acquire().await?;
    let (extra_tokens, resolved_catid) =
        resolve_category(&mut conn, category_id, &tokens).await?;

    let sortby = crate::db::search::SortBy::Title;

    let mut all_ids = db::search::search_archive_ids_only(
        &mut conn,
        &db::search::SearchParams {
            tokens: &tokens,
            category_id: resolved_catid.as_deref(),
            extra_tokens: &extra_tokens,
            sortby,
            sort_desc: false,
            newonly,
            untaggedonly,
            grouptanks,
            hidecompleted,
            start: None,
            keysperpage: None,
        },
    )
    .await?;

    shuffle_vec(&mut all_ids);
    all_ids.truncate(count);

    if all_ids.is_empty() {
        return Ok(Vec::new());
    }

    // Hydrate sampled subset only.
    let hydrated = db::search::fetch_archives_by_ids(&mut conn, &all_ids).await?;
    Ok(hydrated)
}

/// Per-process counter ensuring distinct seeds across rapid back-to-back calls.
static SHUFFLE_COUNTER: AtomicU64 = AtomicU64::new(0);

// Anti-collision seeding: combines nanosecond timestamp with a per-process counter
// so rapid back-to-back calls within the same tick still produce distinct shuffles.
fn shuffle_vec<T>(v: &mut Vec<T>) {
    let n = v.len();
    if n < 2 {
        return;
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before Unix epoch is not supported")
        .as_nanos() as u64;
    let counter = SHUFFLE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let seed = nanos.wrapping_add(counter);
    let mut rng = seed
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(1_442_695_040_888_963_407);
    for i in (1..n).rev() {
        rng = rng
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        let j = (rng >> 33) as usize % (i + 1);
        v.swap(i, j);
    }
}

// Uses a single connection so all prepared statements share one session,
// avoiding named-statement ID collisions when pool checkouts interleave on the same slot.
async fn run_search(pool: &PgPool, input: &SearchInput<'_>) -> Result<(i64, i64, Vec<ArchiveMetadataJson>), sqlx::Error> {
    let mut conn = pool.acquire().await?;

    let filter_str = input.filter.unwrap_or("");
    let tokens = compute_search_filter(filter_str);

    let (extra_tokens, resolved_catid) =
        resolve_category(&mut conn, input.category_id, &tokens).await?;

    let sortby = parse_sortby(input.sortby);
    let sort_desc = resolve_sort_desc(input.order, &sortby);

    let use_pagination = input.start != -1;
    let (start, keysperpage) = if use_pagination {
        (Some(input.start), Some(input.pagesize))
    } else {
        (None, None)
    };

    let total = db::search::total_count(&mut conn, input.grouptanks).await?;

    let search_result = db::search::search_archives(
        &mut conn,
        &SearchParams {
            tokens: &tokens,
            category_id: resolved_catid.as_deref(),
            extra_tokens: &extra_tokens,
            sortby: sortby.clone(),
            sort_desc,
            newonly: input.newonly,
            untaggedonly: input.untaggedonly,
            grouptanks: input.grouptanks,
            hidecompleted: input.hidecompleted,
            start,
            keysperpage,
        },
    )
    .await?;

    let mut archive_filtered = search_result.filtered;
    let mut records: Vec<ArchiveMetadataJson> = search_result
        .records
        .into_iter()
        .map(|r| r.into_dto())
        .collect();

    // Tank results when groupby_tanks
    if input.grouptanks {
        let (tank_filtered, tank_ids) = db::search::search_tanks(
            &mut conn,
            &tokens,
            &extra_tokens,
            resolved_catid.as_deref(),
            &sortby,
            sort_desc,
            start,
            keysperpage,
        )
        .await?;

        archive_filtered += tank_filtered;

        if !tank_ids.is_empty() {
            // Fetch tank metadata and prepend to results
            let tank_dtos = db::search::fetch_tank_dtos(&mut conn, &tank_ids).await?;
            // Prepend: tanks come first (matching PgSearch.pm behaviour)
            let mut combined = tank_dtos;
            combined.extend(records);
            records = combined;
        }
    }

    Ok((total, archive_filtered, records))
}


// Dynamic category: returns extra tokens and no catid. Static category: returns empty tokens and catid.
async fn resolve_category(
    conn: &mut sqlx::PgConnection,
    category_id: Option<&str>,
    _tokens: &[crate::support::search_filter::SearchToken],
) -> Result<(Vec<crate::support::search_filter::SearchToken>, Option<String>), sqlx::Error> {
    let Some(catid) = category_id.filter(|s| !s.is_empty()) else {
        return Ok((Vec::new(), None));
    };

    let row = db::search::get_category(conn, catid).await?;
    let Some(cat) = row else {
        warn!(catid, "category not found; ignoring filter");
        return Ok((Vec::new(), None));
    };

    if let Some(search_filter) = cat.search.filter(|s| !s.is_empty()) {
        // Dynamic category: merge its search filter as extra tokens
        let extra = compute_search_filter(&search_filter);
        Ok((extra, None))
    } else {
        // Static category: add membership WHERE predicate via catid
        Ok((Vec::new(), Some(cat.catid)))
    }
}

/// Resolve the sort direction. Explicit `order=desc`/`order=asc` are honoured;
/// when the client supplies no `order`, fall back to the field's default
/// (`SortBy::default_desc`) so e.g. `lastread` lists most-recently-read first.
fn resolve_sort_desc(order: Option<&str>, sortby: &SortBy) -> bool {
    match order {
        Some("desc") => true,
        Some(_) => false,
        None => sortby.default_desc(),
    }
}

/// Map the sortby string to `SortBy`.
fn parse_sortby(sortby: Option<&str>) -> SortBy {
    match sortby {
        None | Some("") | Some("title") => SortBy::Title,
        Some("lastread") => SortBy::LastRead,
        Some(ns) => {
            // Validate: alphanumeric/underscore/hyphen only
            if ns.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                SortBy::TagNamespace(ns.to_string())
            } else {
                warn!(sortby = ns, "invalid sortby namespace; falling back to title");
                SortBy::Title
            }
        }
    }
}

