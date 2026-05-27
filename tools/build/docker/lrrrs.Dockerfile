FROM rust:1.94-bookworm AS builder

WORKDIR /build

COPY /lrrrs/backend/Cargo.toml lrrrs/backend/Cargo.toml
RUN mkdir -p lrrrs/backend/src
RUN printf 'fn main() {}\n' > lrrrs/backend/src/main.rs
RUN cargo build --manifest-path lrrrs/backend/Cargo.toml --release

COPY /lrrrs/backend lrrrs/backend
# build.rs reads ../../tools/openapi.yaml to emit AUTH_REQUIRED_ROUTES and DTOs;
# without this COPY the second cargo build panics in build.rs.
COPY /tools/openapi.yaml tools/openapi.yaml
RUN cargo build --manifest-path lrrrs/backend/Cargo.toml --release

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -d /home/koyomi -s /bin/bash koyomi
RUN chown -R koyomi:koyomi /home/koyomi

WORKDIR /home/koyomi/lrrrs

COPY --from=builder /build/lrrrs/backend/target/release/lrrrs-backend /usr/local/bin/lrrrs-backend

EXPOSE 3000

USER koyomi
CMD ["lrrrs-backend"]
