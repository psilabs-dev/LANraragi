-- Stamps (reader annotations) table.
--
-- Stamps are per-page annotations on an archive.  The stamp ID is generated
-- as "{arcid}:{page}:{now_ms}" at creation time and is therefore globally
-- unique.  This allows GET/PUT/DELETE /stamps/{id} to resolve a stamp by
-- stampid alone, matching the OpenAPI contract for those routes.
--
-- The `page` column is stored separately for efficient stampsByPage queries.
--
-- No CASCADE: archive deletion must explicitly DELETE FROM lrr_stamp WHERE
-- arcid = $1 before deleting from lrr_archive, matching the FK discipline
-- used by all other join tables in 0001_init.sql.

CREATE TABLE IF NOT EXISTS lrr_stamp (
    stampid     TEXT            PRIMARY KEY,
    arcid       VARCHAR(255)    NOT NULL,
    page        INTEGER         NOT NULL,
    position    TEXT            NOT NULL DEFAULT '',
    content     TEXT            NOT NULL DEFAULT '',
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid)
);

CREATE INDEX IF NOT EXISTS idx_lrr_stamp_arcid_page ON lrr_stamp (arcid, page);
