-- LRRRS initial schema.
--
-- Verbatim port of dev-sql/main DDL from
-- lib/LANraragi/Utils/PsilabsDev/Postgres.pm.
-- Source commit: a94f13c5 (dev-sql/main HEAD at port time).
--
-- ICU is required for the natural_sort collation; migration fails if absent.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE COLLATION IF NOT EXISTS natural_sort (provider = icu, locale = 'en-u-kn-true');

CREATE TABLE IF NOT EXISTS lrr_archive (
    arcid           VARCHAR(255) PRIMARY KEY,
    filename        VARCHAR(255) NOT NULL,
    extension       VARCHAR(255),
    isnew           BOOLEAN NOT NULL,
    lastreadtime    BIGINT NOT NULL,
    pagecount       INTEGER NOT NULL,
    progress        INTEGER NOT NULL,
    title           TEXT COLLATE natural_sort NOT NULL,
    summary         TEXT,
    thumbhash       VARCHAR(255),
    arcsize         BIGINT
);

CREATE TABLE IF NOT EXISTS lrr_category (
    catid           VARCHAR(255) PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    pinned          BOOLEAN NOT NULL,
    search          VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS lrr_tank (
    tankid          VARCHAR(255) PRIMARY KEY,
    name            VARCHAR(255) COLLATE natural_sort NOT NULL,
    summary         TEXT,
    tags            TEXT,
    progress        INTEGER NOT NULL DEFAULT 0,
    lastreadtime    BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS lrr_tag (
    tagid           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    namespace       VARCHAR(255) NOT NULL DEFAULT '',
    value           VARCHAR(255) NOT NULL,
    UNIQUE (namespace, value)
);

CREATE TABLE IF NOT EXISTS lrr_category_to_archive_map (
    catid           VARCHAR(255) NOT NULL,
    arcid           VARCHAR(255) NOT NULL,
    update_date     DATE,
    PRIMARY KEY (catid, arcid),
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid),
    FOREIGN KEY (catid) REFERENCES lrr_category (catid)
);

CREATE TABLE IF NOT EXISTS lrr_archive_to_tag_map (
    arcid           VARCHAR(255) NOT NULL,
    tagid           INTEGER NOT NULL,
    namespace       VARCHAR(255) NOT NULL DEFAULT '',
    value           VARCHAR(255) NOT NULL DEFAULT '',
    update_date     DATE,
    PRIMARY KEY (arcid, tagid),
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid),
    FOREIGN KEY (tagid) REFERENCES lrr_tag (tagid)
);

CREATE TABLE IF NOT EXISTS lrr_tank_to_archive_map (
    tankid          VARCHAR(255) NOT NULL,
    arcid           VARCHAR(255) NOT NULL,
    position        INTEGER NOT NULL,
    update_date     DATE,
    PRIMARY KEY (tankid, arcid),
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid),
    FOREIGN KEY (tankid) REFERENCES lrr_tank (tankid)
);

CREATE TABLE IF NOT EXISTS lrr_toc (
    arcid           VARCHAR(255) NOT NULL,
    page            INTEGER NOT NULL,
    title           TEXT NOT NULL,
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid),
    UNIQUE (arcid, page)
);

CREATE INDEX IF NOT EXISTS idx_lrr_archive_title_trgm ON lrr_archive USING gin (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_lrr_tag_value_trgm ON lrr_tag USING gin (value gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_lrr_archive_to_tag_arcid ON lrr_archive_to_tag_map (arcid);
CREATE INDEX IF NOT EXISTS idx_lrr_archive_to_tag_tagid ON lrr_archive_to_tag_map (tagid);
CREATE INDEX IF NOT EXISTS idx_lrr_archive_isnew ON lrr_archive (isnew);
CREATE INDEX IF NOT EXISTS idx_lrr_category_to_archive_catid ON lrr_category_to_archive_map (catid);
CREATE INDEX IF NOT EXISTS idx_lrr_category_to_archive_arcid ON lrr_category_to_archive_map (arcid);
CREATE INDEX IF NOT EXISTS idx_lrr_category_to_archive_catid_arcid ON lrr_category_to_archive_map (catid, arcid);
CREATE INDEX IF NOT EXISTS idx_lrr_tank_to_archive_tankid ON lrr_tank_to_archive_map (tankid);
CREATE INDEX IF NOT EXISTS idx_lrr_tank_to_archive_arcid ON lrr_tank_to_archive_map (arcid);
CREATE INDEX IF NOT EXISTS idx_lrr_tank_to_archive_tankid_position ON lrr_tank_to_archive_map (tankid, position);
CREATE INDEX IF NOT EXISTS idx_lrr_tag_namespace_trgm ON lrr_tag USING gin (namespace gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_lrr_archive_lastreadtime ON lrr_archive (lastreadtime DESC);
CREATE INDEX IF NOT EXISTS idx_lrr_archive_pagecount ON lrr_archive (pagecount);
CREATE INDEX IF NOT EXISTS idx_lrr_archive_progress ON lrr_archive (progress);
CREATE INDEX IF NOT EXISTS idx_lrr_tag_namespace_value ON lrr_tag (namespace, value);
CREATE INDEX IF NOT EXISTS idx_lrr_tag_lower_namespace_value ON lrr_tag (LOWER(namespace), LOWER(value));
CREATE INDEX IF NOT EXISTS idx_lrr_archive_to_tag_arcid_tagid ON lrr_archive_to_tag_map (arcid, tagid);
CREATE INDEX IF NOT EXISTS idx_lrr_tag_tagid_namespace_value ON lrr_tag (tagid, namespace) INCLUDE (value);
CREATE INDEX IF NOT EXISTS idx_lrr_archive_to_tag_namespace_arcid ON lrr_archive_to_tag_map (namespace, arcid) INCLUDE (tagid, value);
