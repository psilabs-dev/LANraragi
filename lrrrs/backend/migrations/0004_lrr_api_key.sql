-- Single-row API key storage. Argon2id PHC string per row.
--
-- Singleton enforced at the DB level via CHECK (id = 1): only one row can ever
-- exist, regardless of harness or admin bugs. The `id` column is purely the
-- singleton sentinel; it carries no domain meaning.
--
-- Bootstrap: `seed_from_env` inserts a row from LRR_API_KEY env when the table
-- is empty. If the table is non-empty, env is ignored (DB wins). See
-- design.md "Auth (resolved)".

CREATE TABLE IF NOT EXISTS lrr_api_key (
    id          INT NOT NULL PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    key_hash    TEXT NOT NULL,
    created     TIMESTAMPTZ NOT NULL DEFAULT now()
);
