//! OPDS 1.2 + PSE 1.1 catalog generation.
//!
//! Produces well-formed Atom XML consumed by OPDS reader apps. No external XML
//! crate is needed: the output is structurally fixed and written via
//! `write!`/`format!` with per-field XML-character escaping. This is safe
//! because every archive field is escaped before interpolation (see
//! `xml_escape`).

use std::fmt::Write as FmtWrite;

use sqlx::types::chrono::{DateTime, Utc};
use sqlx::PgPool;

use crate::db;
use crate::db::archive::ArchiveRow;
use crate::db::category::CategoryRow;

// Ported from Perl's Mojo::Util::xml_escape behavior.
pub fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&'  => out.push_str("&amp;"),
            '<'  => out.push_str("&lt;"),
            '>'  => out.push_str("&gt;"),
            '"'  => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c    => out.push(c),
        }
    }
    out
}

/// Infers the OPDS acquisition MIME type from the archive file extension.
///
/// Application/zip is poorly supported by OPDS readers; x-cbz and x-cbr are
/// used here, matching Perl's `Model::Opds::get_opds_data`.
///
/// Returns `None` for an empty or unrecognised extension. The column is
/// nullable in the schema; `None` means the caller should omit the MIME type
/// rather than emit a wrong content-type hint.
pub fn mime_for_extension(ext: &str) -> Option<&'static str> {
    match ext.to_ascii_lowercase().as_str() {
        "pdf"          => Some("application/pdf"),
        "rar" | "cbr"  => Some("application/x-cbr"),
        "epub"         => Some("application/epub+zip"),
        "cbz" | "zip"  => Some("application/x-cbz"),
        ""             => None,
        _              => Some("application/x-cbz"),
    }
}

// Ported from Perl's POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($date)) behavior.
pub fn unix_to_iso8601(ts: i64) -> String {
    DateTime::<Utc>::from_timestamp(ts, 0)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
}

/// Intermediate OPDS data for one archive entry, ready for XML rendering.
pub struct OpdsEntry {
    pub arcid:        String,
    pub title:        String,
    /// Tag string used as the Atom `<summary>` element (matches Perl template).
    pub tags:         String,
    pub isnew:        bool,
    pub pagecount:    i32,
    pub progress:     i32,
    pub dateadded:    String,          // ISO 8601
    pub lastreaddate: Option<String>,  // ISO 8601 or None
    pub author:       String,
    pub language:     String,
    pub circle:       String,
    pub event:        String,
    /// `None` when the archive has no extension in the DB (extension IS NULL).
    pub mimetype:     Option<&'static str>,
}

/// Returns the first value for the given namespace in a comma-separated tag
/// string, or `""` if absent.
///
pub fn get_tag_with_namespace<'a>(namespace: &str, tags: &'a str, default: &'a str) -> &'a str {
    let prefix = format!("{namespace}:");
    for tag in tags.split(',') {
        let tag = tag.trim();
        if let Some(val) = tag.strip_prefix(&prefix) {
            return val.trim();
        }
    }
    default
}

/// Fetches a single archive row by arcid, or `None` if the archive is not
/// found or its backing file has no filemap entry.
///
pub async fn fetch_opds_entry(
    pool: &PgPool,
    arcid: &str,
) -> Result<Option<OpdsEntry>, sqlx::Error> {
    let Some(row) = db::archive::get_by_arcid(pool, arcid).await? else {
        return Ok(None);
    };
    // Mirrors Perl's `-e $file` check: skip archives with no filemap entry.
    if db::archive::get_path(pool, arcid).await?.is_none() {
        return Ok(None);
    }
    Ok(Some(row_to_entry(row)))
}

/// Fetches archive rows for the OPDS catalog (title-ordered), optionally
/// filtered to a category, with pagination applied at the service layer.
///
pub async fn fetch_catalog_entries(
    pool: &PgPool,
    cat_id: &str,
    offset: usize,
    limit: usize,
) -> Result<Vec<OpdsEntry>, sqlx::Error> {
    let rows = if cat_id.is_empty() {
        db::archive::list_all_paginated_with_file(pool, offset as i64, limit as i64).await?
    } else {
        db::archive::list_by_category_paginated(pool, cat_id, offset as i64, limit as i64).await?
    };
    Ok(rows.into_iter().map(row_to_entry).collect())
}

/// Fetches all categories.
///
pub async fn fetch_categories(pool: &PgPool) -> Result<Vec<CategoryRow>, sqlx::Error> {
    db::category::list_all(pool).await
}

/// Fetches the archive count for a static category (no search string).
///
pub async fn fetch_static_category_count(
    pool: &PgPool,
    catid: &str,
) -> Result<usize, sqlx::Error> {
    let ids = db::category::list_archives(pool, catid).await?;
    Ok(ids.len())
}

fn row_to_entry(row: ArchiveRow) -> OpdsEntry {
    let tags = row.tags.clone();

    // Parse date_added tag to ISO 8601
    let date_ts: i64 = get_tag_with_namespace("date_added", &tags, "0")
        .parse::<i64>()
        .unwrap_or(0);
    let dateadded = unix_to_iso8601(date_ts);

    // last-read ISO 8601 (only when actually read)
    let lastreaddate = if row.lastreadtime > 0 {
        Some(unix_to_iso8601(row.lastreadtime))
    } else {
        None
    };

    // extension is nullable in the schema; absent extension yields None MIME type.
    let mimetype = row.extension.as_deref().and_then(mime_for_extension);

    OpdsEntry {
        arcid:        xml_escape(&row.arcid),
        title:        xml_escape(&row.title),
        tags:         xml_escape(&row.tags),
        isnew:        row.isnew,
        pagecount:    row.pagecount,
        progress:     row.progress,
        dateadded:    xml_escape(&dateadded),
        lastreaddate: lastreaddate.as_deref().map(xml_escape),
        author:       xml_escape(get_tag_with_namespace("artist",   &tags, "")),
        language:     xml_escape(get_tag_with_namespace("language", &tags, "")),
        circle:       xml_escape(get_tag_with_namespace("group",    &tags, "")),
        event:        xml_escape(get_tag_with_namespace("event",    &tags, "")),
        mimetype,
    }
}

/// Renders the OPDS catalog feed for the given archive list and category list.
///
pub fn render_catalog(
    title: &str,
    motd: &str,
    version: &str,
    cat_id: &str,
    start: usize,
    entries: &[OpdsEntry],
    categories: &[(CategoryRow, Option<usize>)],
    api_key_query: &str,
    api_key_and: &str,
) -> String {
    let title_esc   = xml_escape(title);
    let motd_esc    = xml_escape(motd);
    let version_esc = xml_escape(version);
    let next_start  = start + entries.len();

    let mut out = String::new();
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str("<feed xmlns=\"http://www.w3.org/2005/Atom\"\n");
    out.push_str("    xmlns:dcterms=\"http://purl.org/dc/terms/\"\n");
    out.push_str("    xmlns:opds=\"http://opds-spec.org/2010/catalog\"\n");
    out.push_str("    xmlns:pse=\"http://vaemendis.net/opds-pse/ns\"\n");
    out.push_str("    xmlns:thr=\"http://purl.org/syndication/thread/1.0\">\n\n");

    out.push_str("    <id>urn:lrr:0</id>\n\n");

    let _ = write!(out,
        "    <link rel=\"self\" href=\"/api/opds{api_key_query}\" type=\"application/atom+xml;profile=opds-catalog;kind=acquisition\" />\n"
    );
    let _ = write!(out,
        "    <link rel=\"start\" href=\"/api/opds{api_key_query}\" type=\"application/atom+xml;profile=opds-catalog;kind=acquisition\" />\n"
    );
    let _ = write!(out,
        "    <link rel=\"next\" href=\"/api/opds?start={next_start}{api_key_and}\" type=\"application/atom+xml;profile=opds-catalog;kind=navigation\" />\n\n"
    );

    let _ = write!(out, "    <title>{title_esc}</title>\n");
    out.push_str("    <updated>2010-01-10T10:03:10Z</updated>\n");
    let _ = write!(out, "    <subtitle>{motd_esc}</subtitle>\n");
    out.push_str("    <icon>/favicon.ico</icon>\n");
    out.push_str("    <author>\n");
    let _ = write!(out, "        <name>{version_esc}</name>\n");
    out.push_str("        <uri>http://github.org/Difegue/LANraragi</uri>\n");
    out.push_str("    </author>\n\n");

    // "All Archives" facet link
    let all_active = if cat_id.is_empty() { " opds:activeFacet=\"true\"" } else { "" };
    let _ = write!(out,
        "    <link rel=\"http://opds-spec.org/facet\" href=\"/api/opds{api_key_query}\" title=\"All Archives\" opds:facetGroup=\"Categories\"{all_active} />\n\n"
    );

    // Category facet links
    for (cat, count) in categories {
        let cat_name = xml_escape(&cat.name);
        let cat_active = if cat.catid == cat_id { " opds:activeFacet=\"true\"" } else { "" };
        let count_attr = count.map_or_else(String::new, |n| format!(" thr:count=\"{n}\""));
        let _ = write!(out,
            "    <link rel=\"http://opds-spec.org/facet\" href=\"/api/opds?category={}{api_key_and}\" title=\"{cat_name}\" opds:facetGroup=\"Categories\"{count_attr}{cat_active} />\n",
            xml_escape(&cat.catid),
        );
    }
    out.push('\n');

    // Archive entries
    for entry in entries {
        push_entry(&mut out, entry, api_key_query, api_key_and);
    }

    out.push_str("</feed>\n");
    out
}

/// Renders a single-entry OPDS item feed.
///
pub fn render_item(
    title: &str,
    version: &str,
    entry: &OpdsEntry,
    api_key_query: &str,
    api_key_and: &str,
) -> String {
    let title_esc   = xml_escape(title);
    let version_esc = xml_escape(version);

    let mut out = String::new();
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str("<entry xmlns=\"http://www.w3.org/2005/Atom\"\n");
    out.push_str("    xmlns:thr=\"http://purl.org/syndication/thread/1.0\"\n");
    out.push_str("    xmlns:dcterms=\"http://purl.org/dc/terms/\"\n");
    out.push_str("    xmlns:opds=\"http://opds-spec.org/2010/catalog\"\n");
    out.push_str("    xmlns:pse=\"http://vaemendis.net/opds-pse/ns\"\n");
    out.push_str("    xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    out.push_str("    xmlns:schema=\"http://schema.org/\">\n\n");

    let _ = write!(out,
        "    <link rel=\"start\" href=\"/api/opds{api_key_query}\" type=\"application/atom+xml;profile=opds-catalog;kind=navigation\" />\n"
    );
    let _ = write!(out,
        "    <link rel=\"self\" href=\"/api/opds/{}{api_key_query}\" type=\"application/atom+xml;type=entry;profile=opds-catalog\" />\n\n",
        entry.arcid,
    );

    let _ = write!(out, "    <title>{title_esc}</title>\n");
    let _ = write!(out, "    <id>urn:lrr:{}</id>\n", entry.arcid);
    let _ = write!(out, "    <updated>{}</updated>\n", entry.dateadded);
    let _ = write!(out, "    <published>{}</published>\n", entry.dateadded);
    out.push_str("    <author>\n");
    let _ = write!(out, "        <name>{version_esc}</name>\n");
    out.push_str("    </author>\n");

    push_entry_body(&mut out, entry, api_key_query, api_key_and);

    out.push_str("</entry>\n");
    out
}

// Writes a full <entry> element into the catalog feed string buffer.
fn push_entry(out: &mut String, e: &OpdsEntry, api_key_query: &str, api_key_and: &str) {
    let _ = write!(out, "    <entry>\n");
    let _ = write!(out, "        <title>{}</title>\n", e.title);
    let _ = write!(out, "        <id>urn:lrr:{}</id>\n", e.arcid);
    let _ = write!(out, "        <updated>{}</updated>\n", e.dateadded);
    let _ = write!(out, "        <published>{}</published>\n", e.dateadded);
    out.push_str("        <author>\n");
    let _ = write!(out, "            <name>{}</name>\n", e.author);
    out.push_str("        </author>\n");

    let _ = write!(out,
        "        <link rel=\"alternate\" href=\"/api/opds/{}{api_key_query}\" type=\"application/atom+xml;type=entry;profile=opds-catalog\" />\n",
        e.arcid,
    );

    push_entry_body(out, e, api_key_query, api_key_and);
    let _ = write!(out, "    </entry>\n\n");
}

// Writes the body fields shared by catalog entries and single-item views.
fn push_entry_body(out: &mut String, e: &OpdsEntry, api_key_query: &str, api_key_and: &str) {
    let category_term = if e.isnew { "New Archive" } else { "Archive" };

    let _ = write!(out, "        <rights></rights>\n");
    let _ = write!(out, "        <dcterms:language>{}</dcterms:language>\n", e.language);
    let _ = write!(out, "        <dcterms:publisher>{}</dcterms:publisher>\n", e.circle);
    let _ = write!(out, "        <dcterms:issued>{}</dcterms:issued>\n", e.event);
    let _ = write!(out, "        <category term=\"{category_term}\" />\n");
    let _ = write!(out, "        <summary>{}</summary>\n\n", e.tags);

    let _ = write!(out,
        "        <link rel=\"http://opds-spec.org/image\" href=\"/api/archives/{}/thumbnail{api_key_query}\" type=\"image/jpeg\" />\n",
        e.arcid,
    );
    let _ = write!(out,
        "        <link rel=\"http://opds-spec.org/image/thumbnail\" href=\"/api/archives/{}/thumbnail{api_key_query}\" type=\"image/jpeg\" />\n",
        e.arcid,
    );
    // Omit the type attribute when no MIME type is known for this extension.
    if let Some(mimetype) = e.mimetype {
        let _ = write!(out,
            "        <link rel=\"http://opds-spec.org/acquisition\" href=\"/api/archives/{}/download{api_key_query}\" title=\"Download/Read\" type=\"{mimetype}\" />\n",
            e.arcid,
        );
    } else {
        let _ = write!(out,
            "        <link rel=\"http://opds-spec.org/acquisition\" href=\"/api/archives/{}/download{api_key_query}\" title=\"Download/Read\" />\n",
            e.arcid,
        );
    }

    // PSE stream link
    let last_read_attr = if e.progress > 0 {
        format!(" pse:lastRead=\"{}\"", e.progress)
    } else {
        String::new()
    };
    let last_read_date_attr = e.lastreaddate.as_deref().map_or_else(String::new, |d| {
        format!(" pse:lastReadDate=\"{d}\"")
    });
    let _ = write!(out,
        "        <link rel=\"http://vaemendis.net/opds-pse/stream\" type=\"image/jpeg\" href=\"/api/opds/{}/pse?page={{pageNumber}}{api_key_and}\" pse:count=\"{}\"{last_read_attr}{last_read_date_attr} />\n",
        e.arcid, e.pagecount,
    );

    let _ = write!(out,
        "        <link type=\"text/html\" rel=\"alternate\" title=\"Open in LANraragi\" href=\"/reader?id={}{api_key_and}\" />\n",
        e.arcid,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xml_escape_all_special_chars() {
        assert_eq!(xml_escape("a&<>\"'b"), "a&amp;&lt;&gt;&quot;&#39;b");
    }

    #[test]
    fn xml_escape_clean_string_is_unchanged() {
        assert_eq!(xml_escape("hello world"), "hello world");
    }

    #[test]
    fn mime_for_pdf() {
        assert_eq!(mime_for_extension("pdf"), Some("application/pdf"));
    }

    #[test]
    fn mime_for_cbr() {
        assert_eq!(mime_for_extension("cbr"), Some("application/x-cbr"));
        assert_eq!(mime_for_extension("rar"), Some("application/x-cbr"));
    }

    #[test]
    fn mime_for_epub() {
        assert_eq!(mime_for_extension("epub"), Some("application/epub+zip"));
    }

    #[test]
    fn mime_empty_extension_is_none() {
        assert_eq!(mime_for_extension(""), None);
    }

    #[test]
    fn mime_unknown_extension_falls_back_to_cbz() {
        assert_eq!(mime_for_extension("cbz"), Some("application/x-cbz"));
        assert_eq!(mime_for_extension("zip"), Some("application/x-cbz"));
        assert_eq!(mime_for_extension("xyz"), Some("application/x-cbz"));
    }

    #[test]
    fn unix_to_iso8601_epoch() {
        assert_eq!(unix_to_iso8601(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn unix_to_iso8601_negative_one_second() {
        // ts = -1 must produce 1969-12-31T23:59:59Z, not 1970-01-01T00:00:-1Z
        assert_eq!(unix_to_iso8601(-1), "1969-12-31T23:59:59Z");
    }

    #[test]
    fn unix_to_iso8601_negative_one_hour() {
        // ts = -3600 must produce 1969-12-31T23:00:00Z, not 1969-12-31T-1:00:00Z
        assert_eq!(unix_to_iso8601(-3600), "1969-12-31T23:00:00Z");
    }

    #[test]
    fn unix_to_iso8601_large_positive() {
        // 2023-11-14T22:13:20Z = 1_700_000_000
        assert_eq!(unix_to_iso8601(1_700_000_000), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn unix_to_iso8601_known_date() {
        // 2024-07-02T20:40:58Z = 1719952858
        assert_eq!(unix_to_iso8601(1_719_952_858), "2024-07-02T20:40:58Z");
    }

    #[test]
    fn get_tag_namespace_found() {
        let tags = "artist:wada rco, group:wadamemo, artbook";
        assert_eq!(get_tag_with_namespace("artist", tags, ""), "wada rco");
        assert_eq!(get_tag_with_namespace("group",  tags, ""), "wadamemo");
    }

    #[test]
    fn get_tag_namespace_missing_returns_default() {
        let tags = "artist:wada rco, artbook";
        assert_eq!(get_tag_with_namespace("language", tags, "en"), "en");
    }

    #[test]
    fn get_tag_namespace_empty_tags() {
        assert_eq!(get_tag_with_namespace("artist", "", "fallback"), "fallback");
    }

    #[test]
    fn render_catalog_contains_key_elements() {
        let entries = vec![];
        let cats: Vec<(CategoryRow, Option<usize>)> = vec![];
        let xml = render_catalog("LRR", "Welcome!", "0.1.0", "", 0, &entries, &cats, "", "");
        assert!(xml.contains("<feed xmlns=\"http://www.w3.org/2005/Atom\""));
        assert!(xml.contains("<id>urn:lrr:0</id>"));
        assert!(xml.contains("<title>LRR</title>"));
        assert!(xml.contains("<subtitle>Welcome!</subtitle>"));
        assert!(xml.contains("rel=\"http://opds-spec.org/facet\""));
        assert!(xml.contains("opds:activeFacet=\"true\""));
        assert!(xml.contains("</feed>"));
    }

    #[test]
    fn render_catalog_escapes_special_chars_in_title() {
        let entries = vec![];
        let cats: Vec<(CategoryRow, Option<usize>)> = vec![];
        let xml = render_catalog("L&R", "A<B>C", "0.1", "", 0, &entries, &cats, "", "");
        assert!(xml.contains("<title>L&amp;R</title>"));
        assert!(xml.contains("<subtitle>A&lt;B&gt;C</subtitle>"));
    }

    #[test]
    fn render_item_contains_key_elements() {
        let entry = OpdsEntry {
            arcid:        "abc123".into(),
            title:        "Test Archive".into(),
            tags:         "artist:foo".into(),
            isnew:        false,
            pagecount:    10,
            progress:     3,
            dateadded:    "2024-01-01T00:00:00Z".into(),
            lastreaddate: Some("2024-02-01T00:00:00Z".into()),
            author:       "foo".into(),
            language:     "en".into(),
            circle:       "bar".into(),
            event:        "".into(),
            mimetype:     Some("application/x-cbz"),
        };
        let xml = render_item("LRR", "0.1", &entry, "", "");
        assert!(xml.contains("<entry xmlns=\"http://www.w3.org/2005/Atom\""));
        assert!(xml.contains("<id>urn:lrr:abc123</id>"));
        assert!(xml.contains("pse:lastRead=\"3\""));
        assert!(xml.contains("pse:lastReadDate=\"2024-02-01T00:00:00Z\""));
        assert!(xml.contains("pse:count=\"10\""));
        assert!(xml.contains("application/x-cbz"));
    }
}
