{
  description = "Nix Flake for pg_elixir PostgreSQL extension with PostgreSQL and Elixir dev environment";

  inputs = {
    nixpkgs.follows = "supabase-postgres/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    supabase-postgres.url = "github:supabase/postgres/update-nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, supabase-postgres }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
          config.allowBroken = true;
        };

        # Use PostgreSQL from nixpkgs
        postgresql = pkgs.postgresql_17;

        # Rust toolchain - need newer version for pgrx 0.16.0
        rustVersion = "1.83.0";
        rustToolchain = pkgs.rust-bin.stable.${rustVersion}.default;

        # Build the Elixir sidecar using proper Mix builders
        elixirSidecar = let
          pname = "elixir-sidecar";
          version = "0.1.3";  # Manual acceptor pool implementation (10 acceptors)
          src = ./elixir_sidecar;

          mixFodDeps = pkgs.beamPackages.fetchMixDeps {
            inherit pname version src;
            sha256 = "sha256-cNJw3zFvLf18+/9tCT5bn4zA+bT7T9x564KukjqmG8U=";
            mixEnv = "prod";
          };
        in
        pkgs.beamPackages.mixRelease {
          inherit pname version src mixFodDeps;

          # Add burrito and zig for creating standalone executable
          nativeBuildInputs = with pkgs; [
            zig_0_14
            xz
            p7zip
            makeWrapper
          ];

          # Override the build phase to use burrito
          buildPhase = ''
            runHook preBuild

            export MIX_ENV=prod
            export HOME=$TMPDIR

            # Standard mix compile
            mix compile --no-deps-check

            # Build with burrito for standalone executable
            mix release elixir_sidecar

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin

            # Copy the burrito-generated standalone executable
            if [ -d burrito_out ]; then
              cp burrito_out/elixir_sidecar_* $out/bin/elixir_sidecar
              chmod +x $out/bin/elixir_sidecar
            else
              # Fallback to standard release if burrito fails
              cp -r _build/prod/rel/elixir_sidecar $out/
              makeWrapper $out/elixir_sidecar/bin/elixir_sidecar $out/bin/elixir_sidecar
            fi

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Elixir sidecar for pg_elixir PostgreSQL extension";
            platforms = platforms.unix;
            license = licenses.asl20;
          };
        };

        # Use buildPgrxExtension from nixpkgs
        buildPgrxExtension = pkgs.buildPgrxExtension;

        # Package the pg_elixir extension with embedded sidecar
        pgElixir = buildPgrxExtension {
          pname = "pg_elixir";
          version = "0.1.3";  # Manual acceptor pool (10 acceptors)
          inherit postgresql;
          cargo-pgrx = supabase-postgres.packages.${system}.cargo-pgrx_0_14_3;

          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          nativeBuildInputs = [ rustToolchain ];

          buildInputs = [
            postgresql
            elixirSidecar
          ];

          # Skip tests for now due to complexity
          doCheck = false;

          # Generate pgrx schema SQL before install
          preBuild = ''
            export PG_CONFIG=${postgresql}/bin/pg_config
          '';

          # Include the elixir sidecar in the output
          postInstall = ''
            # The pgrx build should have generated the SQL file with function declarations
            # If it exists, append our custom schema/tables to it
            if [ -f $out/share/postgresql/extension/pg_elixir--0.1.0.sql ]; then
              # Append custom SQL to pgrx-generated functions
              cat ${./pg_elixir--0.1.0.sql} >> $out/share/postgresql/extension/pg_elixir--0.1.0.sql
            else
              # If pgrx didn't generate SQL, use ours (though functions won't work)
              mkdir -p $out/share/postgresql/extension
              cp ${./pg_elixir--0.1.0.sql} $out/share/postgresql/extension/pg_elixir--0.1.0.sql
            fi

            # Create a bin directory in the extension output
            mkdir -p $out/bin
            # Copy the elixir sidecar executable
            cp ${elixirSidecar}/bin/elixir_sidecar $out/bin/

            # Create a configuration file with the sidecar path
            mkdir -p $out/share
            echo "${elixirSidecar}/bin/elixir_sidecar" > $out/share/elixir_sidecar_path
          '';

          meta = with pkgs.lib; {
            description = "PostgreSQL extension for running Elixir/BEAM as a background worker sidecar";
            homepage = "https://github.com/yourusername/pg_elixir";
            platforms = platforms.unix;
            license = licenses.asl20;
          };
        };

        # Create a custom PostgreSQL package with the extension included
        postgresqlWithPlugins = postgresql.withPackages (ps: [ pgElixir ]);

        # Script to start PostgreSQL with proper configuration
        startPostgresScript = pkgs.writeShellScriptBin "start-postgres" ''
          PGDATA=$HOME/pgdata
          SOCKET_DIR=$HOME/pg_sockets

          if [ ! -d "$PGDATA" ]; then
            echo "Initializing PostgreSQL data directory..."
            mkdir -p "$SOCKET_DIR"
            ${postgresqlWithPlugins}/bin/initdb -D $PGDATA

            # Configure PostgreSQL for the extension
            cat >> $PGDATA/postgresql.conf << EOF
          # Load pg_elixir extension at startup - this will start the Elixir sidecar background worker
          shared_preload_libraries = 'pg_elixir'

          # Extension configuration
          elixir.enabled = true
          elixir.executable_path = '${pgElixir}/bin/elixir_sidecar'
          elixir.socket_path = '$HOME/pg_elixir.sock'
          elixir.request_timeout_ms = 30000
          elixir.max_restarts = 5
          elixir.memory_limit_mb = 2048

          # PostgreSQL settings
          unix_socket_directories = '$SOCKET_DIR'
          port = 5432
          listen_addresses = 'localhost'
          EOF
          fi

          echo "Cleaning up old Elixir processes and cache..."
          pkill -9 beam.smp 2>/dev/null || true
          rm -rf "$HOME/Library/Application Support/.burrito/elixir_sidecar"* 2>/dev/null || true
          sleep 1

          echo "Starting PostgreSQL..."
          export PGHOST="$SOCKET_DIR"
          ${postgresqlWithPlugins}/bin/pg_ctl -D $PGDATA -l $PGDATA/logfile start
          echo "PostgreSQL started. Use 'psql postgres' to connect."
        '';

        # Script to stop PostgreSQL
        stopPostgresScript = pkgs.writeShellScriptBin "stop-postgres" ''
          PGDATA=$HOME/pgdata
          SOCKET_DIR=$HOME/pg_sockets
          export PGHOST="$SOCKET_DIR"

          echo "Stopping PostgreSQL..."
          ${postgresqlWithPlugins}/bin/pg_ctl -D $PGDATA stop

          echo "Cleaning up Elixir processes and cache..."
          pkill -9 beam.smp 2>/dev/null || true
          rm -rf "$HOME/Library/Application Support/.burrito/elixir_sidecar"* 2>/dev/null || true

          echo "PostgreSQL stopped."
        '';

        # Script to create test database and install extension
        setupExtensionScript = pkgs.writeShellScriptBin "setup-extension" ''
          SOCKET_DIR=$HOME/pg_sockets
          export PGHOST="$SOCKET_DIR"

          echo "Creating test database..."
          ${postgresqlWithPlugins}/bin/createdb pg_elixir_test || echo "Database may already exist"

          echo "Installing pg_elixir extension..."
          ${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -c "CREATE EXTENSION IF NOT EXISTS pg_elixir;"

          echo "Waiting for Elixir sidecar to start..."
          sleep 2

          echo "Testing basic functionality..."
          ${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -c "SELECT elixir_call('echo', '{\"message\": \"Hello from pg_elixir!\"}'::jsonb);"

          echo "Extension setup complete!"
        '';

        # Script to run the example queries
        runExamplesScript = pkgs.writeShellScriptBin "run-examples" ''
          SOCKET_DIR=$HOME/pg_sockets
          export PGHOST="$SOCKET_DIR"

          echo "Running basic examples..."
          ${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -f ${./examples/basic_usage.sql}

          echo "Examples completed!"
        '';

        # Script to check extension health
        checkHealthScript = pkgs.writeShellScriptBin "check-health" ''
          SOCKET_DIR=$HOME/pg_sockets
          export PGHOST="$SOCKET_DIR"

          echo "Checking pg_elixir health..."
          ${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -c "SELECT * FROM elixir_health();"
        '';

        # Script to restart the Elixir sidecar
        restartElixirScript = pkgs.writeShellScriptBin "restart-elixir" ''
          SOCKET_DIR=$HOME/pg_sockets
          export PGHOST="$SOCKET_DIR"

          echo "Restarting Elixir sidecar..."
          ${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -c "SELECT elixir_restart();"
          echo "Elixir sidecar restarted!"
        '';

        # Script to reset PostgreSQL data directory
        resetPostgresScript = pkgs.writeShellScriptBin "reset-postgres" ''
          PGDATA=$HOME/pgdata
          SOCKET_DIR=$HOME/pg_sockets
          export PGHOST="$SOCKET_DIR"

          echo "Stopping PostgreSQL (if running)..."
          ${postgresqlWithPlugins}/bin/pg_ctl -D $PGDATA stop 2>/dev/null || true

          echo "Removing old data directory..."
          rm -rf "$PGDATA" "$SOCKET_DIR"

          echo "Reset complete. Run 'start-postgres' to initialize a fresh instance."
        '';

        # Script to run tests
        testScript = pkgs.writeShellScriptBin "test-extension" ''
          SOCKET_DIR=$HOME/pg_sockets
          export PGHOST="$SOCKET_DIR"

          echo "Running pg_elixir tests..."

          # Test basic functionality
          echo "Testing echo function..."
          result=$(${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -t -c "SELECT elixir_call('echo', '{\"test\": \"value\"}'::jsonb);")
          echo "Result: $result"

          # Test mathematical operations
          echo "Testing add function..."
          result=$(${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -t -c "SELECT elixir_call('add', '{\"a\": 5, \"b\": 3}'::jsonb);")
          echo "Result: $result"

          # Test async operations
          echo "Testing async operations..."
          request_id=$(${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -t -c "SELECT elixir_call_async('multiply', '{\"a\": 4, \"b\": 7}'::jsonb);")
          echo "Async request ID: $request_id"

          # Wait a bit and check result
          sleep 1
          result=$(${postgresqlWithPlugins}/bin/psql -d pg_elixir_test -t -c "SELECT elixir_get_result('$request_id'::uuid);")
          echo "Async result: $result"

          echo "All tests completed!"
        '';

        # Development script to rebuild and reinstall
        devRebuildScript = pkgs.writeShellScriptBin "dev-rebuild" ''
          echo "Rebuilding pg_elixir extension..."

          # Stop PostgreSQL
          stop-postgres

          # Rebuild the flake
          nix build .#pgElixir

          # Reset and restart PostgreSQL
          reset-postgres
          start-postgres
          setup-extension

          echo "Rebuild complete!"
        '';

      in {
        packages = {
          pgElixir = pgElixir;
          elixirSidecar = elixirSidecar;
          postgresqlWithPlugins = postgresqlWithPlugins;
          default = pgElixir;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            # PostgreSQL with our extension
            postgresqlWithPlugins

            # Development tools
            rustToolchain
            pkgs.elixir
            pkgs.erlang
            pkgs.cargo-watch
            pkgs.cargo-edit

            # Scripts
            startPostgresScript
            stopPostgresScript
            setupExtensionScript
            runExamplesScript
            checkHealthScript
            restartElixirScript
            resetPostgresScript
            testScript
            devRebuildScript
          ];

          shellHook = ''
            echo "🚀 Development environment for pg_elixir"
            echo "PostgreSQL with pg_elixir extension: ${postgresqlWithPlugins}/bin"
            echo "Built-in Elixir sidecar: ${pgElixir}/bin/elixir_sidecar"
            echo ""
            echo "📋 Available commands:"
            echo "  start-postgres      - Initialize and start PostgreSQL with pg_elixir"
            echo "  stop-postgres       - Stop PostgreSQL"
            echo "  setup-extension     - Create test DB and install pg_elixir extension"
            echo "  run-examples        - Run example SQL queries"
            echo "  check-health        - Check pg_elixir health status"
            echo "  restart-elixir      - Restart the Elixir sidecar process"
            echo "  test-extension      - Run basic functionality tests"
            echo "  reset-postgres      - Reset data directory and re-init PostgreSQL"
            echo "  dev-rebuild         - Rebuild extension and restart PostgreSQL"
            echo ""
            echo "🔧 Database connection:"
            echo "  psql -d pg_elixir_test  - Connect to test database"
            echo ""
            echo "💡 Quick start:"
            echo "  1. start-postgres     (starts PostgreSQL with extension ready)"
            echo "  2. setup-extension    (creates DB and installs extension)"
            echo "  3. run-examples       (demonstrates functionality)"
            echo ""
            echo "ℹ️  The Elixir sidecar runs automatically as a PostgreSQL background worker"
            echo "   No separate Elixir node needed - everything is built into the extension!"
            echo ""

            export PGDATA=$HOME/pgdata
            export PGHOST=$HOME/pg_sockets
            export PGUSER=$USER
            export PATH=${postgresqlWithPlugins}/bin:$PATH

            # Set Rust environment
            export RUST_LOG=debug
            export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
          '';
        };

        # Additional outputs for CI/development
        checks = {
          build-extension = pgElixir;
          build-sidecar = elixirSidecar;
        };

        apps = {
          start-postgres = {
            type = "app";
            program = "${startPostgresScript}/bin/start-postgres";
          };

          test = {
            type = "app";
            program = "${testScript}/bin/test-extension";
          };
        };
      }
    );
}