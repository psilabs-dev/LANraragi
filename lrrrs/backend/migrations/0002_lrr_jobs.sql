CREATE TYPE lrr_job_state AS ENUM ('inactive', 'active', 'finished', 'failed');

CREATE TABLE IF NOT EXISTS lrr_jobs (
    id              BIGSERIAL PRIMARY KEY,
    task            TEXT NOT NULL,
    args            JSONB NOT NULL DEFAULT '[]'::JSONB,
    priority        INTEGER NOT NULL DEFAULT 0,
    state           lrr_job_state NOT NULL DEFAULT 'inactive',
    notes           JSONB NOT NULL DEFAULT '{}'::JSONB,
    error           TEXT,
    created         BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM now())::BIGINT,
    started         BIGINT,
    finished        BIGINT
);

-- Partial index used by the worker's FOR UPDATE SKIP LOCKED claim query.
CREATE INDEX IF NOT EXISTS lrr_jobs_claim_idx
    ON lrr_jobs (priority DESC, id ASC)
    WHERE state = 'inactive';
