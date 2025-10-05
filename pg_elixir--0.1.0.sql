-- pg_elixir extension SQL definitions
-- Version: 0.1.0

-- Rust function declarations (from pgrx)
CREATE FUNCTION elixir_call(function_name text, args jsonb) RETURNS text
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'elixir_call_wrapper';

CREATE FUNCTION elixir_call_async(function_name text, args jsonb) RETURNS text
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'elixir_call_async_wrapper';

CREATE FUNCTION elixir_get_result(request_id text) RETURNS text
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'elixir_get_result_wrapper';

CREATE FUNCTION elixir_health() RETURNS text
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'elixir_health_wrapper';

CREATE FUNCTION elixir_restart() RETURNS boolean
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'elixir_restart_wrapper';

CREATE FUNCTION elixir_load_code(module_name text, source_code text) RETURNS boolean
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'elixir_load_code_wrapper';

-- Create schema for the extension (using elixir_ext instead of pg_elixir)
CREATE SCHEMA IF NOT EXISTS elixir_ext;

-- Grant usage on schema
GRANT USAGE ON SCHEMA elixir_ext TO PUBLIC;

-- Create a table to store async results (optional, for persistence)
CREATE TABLE IF NOT EXISTS elixir_ext.async_results (
    request_id UUID PRIMARY KEY,
    result JSONB,
    status TEXT CHECK (status IN ('pending', 'completed', 'failed')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_async_results_status
    ON elixir_ext.async_results(status);

CREATE INDEX IF NOT EXISTS idx_async_results_created
    ON elixir_ext.async_results(created_at);

-- Create a table for function metrics
CREATE TABLE IF NOT EXISTS elixir_ext.function_metrics (
    function_name TEXT NOT NULL,
    call_count BIGINT DEFAULT 0,
    total_duration_ms BIGINT DEFAULT 0,
    avg_duration_ms BIGINT GENERATED ALWAYS AS (
        CASE WHEN call_count > 0
        THEN total_duration_ms / call_count
        ELSE 0 END
    ) STORED,
    last_called TIMESTAMPTZ,
    last_error TEXT,
    error_count BIGINT DEFAULT 0,
    PRIMARY KEY (function_name)
);

-- Helper function to clean up old async results
CREATE OR REPLACE FUNCTION elixir_ext.cleanup_old_results()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM elixir_ext.async_results
    WHERE created_at < NOW() - INTERVAL '1 hour'
    AND status = 'completed';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Create a scheduled job to clean up old results (requires pg_cron)
-- Uncomment if pg_cron is available:
-- SELECT cron.schedule('cleanup_elixir_results', '0 * * * *',
--     'SELECT elixir_ext.cleanup_old_results();');

-- Wrapper function for better error handling
CREATE OR REPLACE FUNCTION elixir_ext.safe_call(
    function_name TEXT,
    args JSONB,
    timeout_ms INTEGER DEFAULT 30000
) RETURNS JSONB AS $$
DECLARE
    result JSONB;
    start_time TIMESTAMPTZ;
    duration_ms BIGINT;
BEGIN
    start_time := clock_timestamp();

    -- Call the main function
    result := elixir_call(function_name, args);

    -- Calculate duration
    duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;

    -- Update metrics
    INSERT INTO elixir_ext.function_metrics (
        function_name,
        call_count,
        total_duration_ms,
        last_called
    ) VALUES (
        function_name,
        1,
        duration_ms,
        NOW()
    )
    ON CONFLICT (function_name) DO UPDATE SET
        call_count = elixir_ext.function_metrics.call_count + 1,
        total_duration_ms = elixir_ext.function_metrics.total_duration_ms + duration_ms,
        last_called = NOW();

    RETURN result;

EXCEPTION WHEN OTHERS THEN
    -- Log error to metrics
    INSERT INTO elixir_ext.function_metrics (
        function_name,
        error_count,
        last_error,
        last_called
    ) VALUES (
        function_name,
        1,
        SQLERRM,
        NOW()
    )
    ON CONFLICT (function_name) DO UPDATE SET
        error_count = elixir_ext.function_metrics.error_count + 1,
        last_error = SQLERRM,
        last_called = NOW();

    RAISE;
END;
$$ LANGUAGE plpgsql;

-- View for monitoring function performance
CREATE OR REPLACE VIEW elixir_ext.function_stats AS
SELECT
    function_name,
    call_count,
    error_count,
    CASE WHEN call_count > 0
        THEN (error_count::FLOAT / call_count * 100)::NUMERIC(5,2)
        ELSE 0
    END AS error_rate_percent,
    avg_duration_ms,
    last_called,
    last_error
FROM elixir_ext.function_metrics
ORDER BY call_count DESC;

-- Grant permissions
GRANT SELECT ON elixir_ext.function_stats TO PUBLIC;
GRANT SELECT, INSERT, UPDATE ON elixir_ext.async_results TO PUBLIC;
GRANT SELECT, INSERT, UPDATE ON elixir_ext.function_metrics TO PUBLIC;

-- Extension version comment
COMMENT ON EXTENSION pg_elixir IS 'PostgreSQL extension for running Elixir/BEAM as a background worker sidecar';