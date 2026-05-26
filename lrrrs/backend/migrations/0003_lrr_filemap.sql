CREATE TABLE IF NOT EXISTS lrr_filemap (
    path  TEXT PRIMARY KEY,
    arcid VARCHAR(255) NOT NULL REFERENCES lrr_archive(arcid) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS lrr_filemap_arcid_idx ON lrr_filemap(arcid);
