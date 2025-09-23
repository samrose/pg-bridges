# Multi-stage Docker build for pg_elixir

# Stage 1: Build Elixir sidecar
FROM hexpm/elixir:1.16.2-erlang-26.2.5-alpine-3.19.1 AS elixir-builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache build-base git

# Copy Elixir project
COPY elixir_sidecar .

# Install dependencies and build release
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    MIX_ENV=prod mix release elixir_sidecar

# Stage 2: Build Rust extension
FROM rust:1.75-alpine AS rust-builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    musl-dev \
    postgresql16-dev \
    openssl-dev \
    clang-dev

# Install pgrx
RUN cargo install --locked cargo-pgrx --version 0.11.2

# Copy Rust project
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY pg_elixir.control ./
COPY pg_elixir--0.1.0.sql ./

# Initialize pgrx and build
RUN cargo pgrx init --pg16 /usr/bin/pg_config
RUN cargo pgrx package --pg16

# Stage 3: Final runtime image
FROM postgres:16-alpine

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    libstdc++

# Create extension directory
RUN mkdir -p /usr/local/lib/postgresql

# Copy built extension from rust-builder
COPY --from=rust-builder /app/target/release/pg_elixir/lib/pg_elixir.so /usr/local/lib/postgresql/
COPY --from=rust-builder /app/target/release/pg_elixir/share/extension/pg_elixir.control /usr/share/postgresql/extension/
COPY --from=rust-builder /app/target/release/pg_elixir/share/extension/pg_elixir--0.1.0.sql /usr/share/postgresql/extension/

# Copy Elixir sidecar from elixir-builder
COPY --from=elixir-builder /app/_build/prod/rel/elixir_sidecar/elixir_sidecar /usr/local/lib/postgresql/elixir_sidecar
RUN chmod +x /usr/local/lib/postgresql/elixir_sidecar

# Configure PostgreSQL for the extension
RUN echo "shared_preload_libraries = 'pg_elixir'" >> /usr/local/share/postgresql/postgresql.conf.sample
RUN echo "elixir.enabled = true" >> /usr/local/share/postgresql/postgresql.conf.sample
RUN echo "elixir.executable_path = '/usr/local/lib/postgresql/elixir_sidecar'" >> /usr/local/share/postgresql/postgresql.conf.sample
RUN echo "elixir.socket_path = '/tmp/pg_elixir.sock'" >> /usr/local/share/postgresql/postgresql.conf.sample

# Create initialization script
COPY <<EOF /docker-entrypoint-initdb.d/01-create-extension.sql
-- Create the pg_elixir extension
CREATE EXTENSION IF NOT EXISTS pg_elixir;

-- Test basic functionality
SELECT elixir_call('echo', '{"message": "Extension loaded successfully!"}'::jsonb);
EOF

# Expose PostgreSQL port
EXPOSE 5432

# Use the standard PostgreSQL entrypoint
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]