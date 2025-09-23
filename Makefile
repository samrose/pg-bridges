# pg_elixir Makefile

.PHONY: help build install test clean elixir-build elixir-test setup dev

# Default target
help:
	@echo "Available targets:"
	@echo "  setup        - Install dependencies and initialize pgrx"
	@echo "  build        - Build the PostgreSQL extension"
	@echo "  install      - Install the extension to PostgreSQL"
	@echo "  test         - Run all tests"
	@echo "  elixir-build - Build the Elixir sidecar"
	@echo "  elixir-test  - Run Elixir tests"
	@echo "  clean        - Clean build artifacts"
	@echo "  dev          - Set up development environment"

# Install dependencies and initialize pgrx
setup:
	@echo "Installing Rust dependencies..."
	rustup update stable
	cargo install --locked cargo-pgrx --version 0.11.2
	@echo "Initializing pgrx..."
	cargo pgrx init
	@echo "Installing Elixir dependencies..."
	cd elixir_sidecar && mix deps.get

# Build the PostgreSQL extension
build:
	@echo "Building PostgreSQL extension..."
	cargo pgrx package

# Install the extension
install: build elixir-build
	@echo "Installing extension..."
	cargo pgrx install --release

# Build the Elixir sidecar
elixir-build:
	@echo "Building Elixir sidecar..."
	cd elixir_sidecar && MIX_ENV=prod mix release elixir_sidecar

# Run PostgreSQL extension tests
test:
	@echo "Running PostgreSQL extension tests..."
	cargo pgrx test

# Run Elixir tests
elixir-test:
	@echo "Running Elixir tests..."
	cd elixir_sidecar && mix test

# Run all tests
test-all: test elixir-test

# Clean build artifacts
clean:
	@echo "Cleaning Rust artifacts..."
	cargo clean
	@echo "Cleaning Elixir artifacts..."
	cd elixir_sidecar && mix clean

# Development setup
dev: setup
	@echo "Setting up development environment..."
	@echo "Creating local PostgreSQL instance for testing..."
	cargo pgrx start pg16
	@echo "Creating extension..."
	cargo pgrx install --pg16
	@echo "Development environment ready!"
	@echo "Connect to test database with: psql pg_elixir"

# Quick development iteration
dev-install: build elixir-build
	cargo pgrx install --pg16
	@echo "Extension updated in development database"

# Package for distribution
package: build elixir-build
	@echo "Creating distribution package..."
	mkdir -p dist
	cp target/release/pg_elixir/lib/pg_elixir.so dist/
	cp pg_elixir.control dist/
	cp pg_elixir--0.1.0.sql dist/
	cp elixir_sidecar/_build/prod/rel/elixir_sidecar/elixir_sidecar dist/
	@echo "Distribution package created in dist/"

# Benchmark the extension
benchmark:
	@echo "Running performance benchmarks..."
	cd elixir_sidecar && mix run --no-halt -e "ElixirSidecar.Benchmark.run()"

# Format code
format:
	@echo "Formatting Rust code..."
	cargo fmt
	@echo "Formatting Elixir code..."
	cd elixir_sidecar && mix format

# Lint code
lint:
	@echo "Linting Rust code..."
	cargo clippy -- -D warnings
	@echo "Linting Elixir code..."
	cd elixir_sidecar && mix credo

# Check dependencies for security vulnerabilities
security-check:
	@echo "Checking Rust dependencies..."
	cargo audit
	@echo "Checking Elixir dependencies..."
	cd elixir_sidecar && mix deps.audit

# Generate documentation
docs:
	@echo "Generating Rust documentation..."
	cargo doc --no-deps
	@echo "Generating Elixir documentation..."
	cd elixir_sidecar && mix docs
	@echo "Documentation generated!"

# Docker build
docker-build:
	@echo "Building Docker image..."
	docker build -t pg_elixir:latest .

# Run in Docker
docker-run:
	@echo "Running in Docker..."
	docker run -it --rm pg_elixir:latest