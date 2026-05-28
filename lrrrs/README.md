# LRRRS (LANraragi in Rust)

A *Rust rewrite* of LRR with the database backend switched from Redis to Postgres. The frontend will also be rewritten.

Why?!

1. Lower memory consumption of Rust, less OOM
2. Faster performance of a low-level programming language while keeping memory safety (Rust)
3. ACID compliance and data integrity guarantees of Postgres
4. Fast search (still Postgres)
5. Great compiler support (Rust)

LRRRS implements the upstream OpenAPI contract minus plugins. There is no plugin system.

LRRRS-exclusive endpoints live under `/api/rs/*` to avoid colliding with LRR's `/api/*` surface.

## What Changes

You no longer have these:

- Redis as a database
- All plugin support (including downloading)
- Batch operation support
- Windows support
- Homebrew support
- TT2/JQuery UI
- File logging
- Archive format support beyond ZIP/CBZ (RAR, CBR, 7z, tar variants, EPUB, PDF rejected at upload; convert to ZIP/CBZ before migrating)
- Image format support beyond JPEG/PNG/WebP/GIF (AVIF, TIFF, HEIC, JP2, etc. rejected at upload; convert images before migrating)
- OpenAPI runtime validation

The OpenAPI schema is served at OAS 3.0.3.

If you need *any* of the above, then don't switch.

If you like LRR the way it is but want *faster search* and already have a stable LRR running, and you don't mind figuring things out yourself: try this out!

## Switching from Perl LRR

LRRRS uses API-key-only authentication; there is no login page or session cookies.
Pass the key as `Authorization: Bearer <base64(key)>` or `?key=<plaintext>`. Existing Perl LRR Bearer clients that already base64-encode the key are unaffected.

## Quick Start (Docker Compose)

Recommended path for trying LRRRS:

```sh
docker compose -f tools/build/docker/lrrrs.docker-compose.yml up --build
```

Stop the stack:

```sh
docker compose -f tools/build/docker/lrrrs.docker-compose.yml down
```

## Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `LRR_API_KEY` | _(unset)_ | Bootstrap-only API key. On first boot with an empty `lrr_api_key` table, if unset, LRRRS runs in read-only mode (401 on secured routes). Once the key is seeded to the DB, this variable is not required on subsequent restarts. If the `lrr_api_key` table is already populated, this variable is ignored on restart — the DB value wins. |
| `LRR_BIND_ADDR` | `0.0.0.0:3000` | Server listen address. Invalid value fails startup. |
| `LRR_POSTGRES_HOST` | `localhost` | |
| `LRR_POSTGRES_PORT` | `5432` | |
| `LRR_POSTGRES_USER` | `lanraragi` | |
| `LRR_POSTGRES_PASSWORD` | `lanraragi` | |
| `LRR_POSTGRES_DB` | `lanraragi` | |
| `LRR_CONTENT_DIR` | `./content` | Root directory where uploaded archives are stored. Created on first upload if missing. |
| `LRR_THUMB_DIR` | `./thumb` | Directory for cover and per-page WebP thumbnails. |
| `LRR_TEMP_DIR` | `./temp` | Directory for lazy-extracted archive pages. |
| `LRR_RAYON_THREADS` | host core count | Size of the Rayon pool used for CPU-bound work (archive probing, page extraction, thumbnail encoding, Argon2 verification). |
| `RUST_LOG` | `lrrrs_backend=info,axum=info,sqlx=warn` | Use `RUST_LOG=debug` for verbose logs. |

To rotate the key: `DELETE FROM lrr_api_key;` then restart the container with the new value set.

## Local Development

Local-only development; requires a Postgres instance reachable at `LRR_POSTGRES_*`.

```sh
cargo build --manifest-path lrrrs/backend/Cargo.toml
cargo run --manifest-path lrrrs/backend/Cargo.toml
```

Build the docker image directly:

```sh
docker build -f tools/build/docker/lrrrs.Dockerfile -t lrrrs-backend:test .
```
