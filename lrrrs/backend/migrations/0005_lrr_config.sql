-- Singleton config row. All fields formerly lived in Perl LRR's Redis
-- LRR_CONFIG hash; LRRRS persists them here. No env vars override these;
-- the only mutation paths are SQL (test harness, operator psql) followed by
-- container restart. See design.md "Auth (resolved)".

CREATE TABLE IF NOT EXISTS lrr_config (
    id                   INT NOT NULL PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    nofunmode            BOOLEAN NOT NULL DEFAULT FALSE,
    enablecors           BOOLEAN NOT NULL DEFAULT FALSE,
    authprogress         BOOLEAN NOT NULL DEFAULT FALSE,
    localprogress        BOOLEAN NOT NULL DEFAULT FALSE,
    pagesize             INTEGER NOT NULL DEFAULT 100 CHECK (pagesize > 0),
    bookmark_link        VARCHAR(255),
    excluded_namespaces  TEXT NOT NULL DEFAULT ''
);

INSERT INTO lrr_config (id) VALUES (1) ON CONFLICT DO NOTHING;
