# LRRRS (LANraragi in Rust)

A *Rust rewrite* of LRR with the database backend switched from Redis (Valkey) to Postgres. The frontend will also be rewritten.

Why?!

1. Lower memory consumption of Rust, less OOM
2. Faster performance of a low-level programming language while keeping memory safety (Rust)
3. ACID compliance and data integrity guarantees of Postgres
4. Fast search (still Postgres)
5. Great compiler support (Rust)

LRRRS implements the full upstream OpenAPI contract; the only documented exception is plugin endpoints, which return 501. Whatever API exists in LRR is supported by LRRRS, even if it no-ops.

LRRRS-exclusive endpoints live under `/api/rs/*` to avoid colliding with LRR's `/api/*` surface.

## What Changes

You no longer have these:

- Redis/Valkey as a database
- All plugin support (including downloading)
- Batch operation support
- Windows support
- Homebrew support
- TT2/JQuery UI
- File logging
- Archive format support beyond ZIP/CBZ (RAR/CBR, 7z, tar variants, EPUB, PDF are all rejected at upload)
- Image format support beyond JPEG/PNG/WebP/GIF
- OpenAPI runtime validation
- Stability and features

If you need *any* of the above, then don't switch.

If you like LRR the way it is but want *faster search* and already have a stable LRR running, and you don't mind figuring things out yourself: try this out!

## Switching from Perl LRR

Session cookies are not interoperable: existing browser logins are invalidated when switching backends. Log in once after the switchover. API keys (`Authorization: Bearer …`) are not affected by this.

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
| `LRR_BIND_ADDR` | `0.0.0.0:3000` | Server listen address. Parsed as `SocketAddr`; invalid value fails startup. |
| `LRR_POSTGRES_HOST` | `localhost` | |
| `LRR_POSTGRES_PORT` | `5432` | |
| `LRR_POSTGRES_USER` | `lanraragi` | |
| `LRR_POSTGRES_PASSWORD` | `lanraragi` | |
| `LRR_POSTGRES_DB` | `lanraragi` | |
| `LRR_CONTENT_DIR` | `./content` | Root directory where uploaded archives are stored. Created on first upload if missing. |
| `LRR_RAYON_THREADS` | host core count | Size of the Rayon pool used for CPU-bound work (ZIP probing, future thumbnail / dedup). |
| `RUST_LOG` | `lrrrs_backend=info,axum=info,sqlx=warn` | Standard `tracing-subscriber` filter syntax. Use `RUST_LOG=debug` for verbose logs. |

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
