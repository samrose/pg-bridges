-- pg_elixir Basic Usage Examples

-- 1. Simple function calls
SELECT elixir_call('echo', '{"message": "Hello, World!"}'::jsonb);

-- 2. Mathematical operations
SELECT elixir_call('add', '{"a": 10, "b": 25}'::jsonb);
SELECT elixir_call('multiply', '{"a": 7, "b": 8}'::jsonb);

-- 3. String operations
SELECT elixir_call('uppercase', '{"text": "hello from postgresql"}'::jsonb);
SELECT elixir_call('concat', '{"strings": ["Hello", " ", "World", "!"]}'::jsonb);

-- 4. System information
SELECT elixir_call('system_info', '{}'::jsonb);

-- 5. Asynchronous operations
DO $$
DECLARE
    request_id UUID;
    result JSONB;
BEGIN
    -- Start an async operation
    SELECT elixir_call_async('multiply', '{"a": 123, "b": 456}'::jsonb) INTO request_id;

    RAISE NOTICE 'Started async operation with ID: %', request_id;

    -- Wait a bit and check the result
    PERFORM pg_sleep(0.1);

    SELECT elixir_get_result(request_id) INTO result;

    IF result IS NOT NULL THEN
        RAISE NOTICE 'Result: %', result;
    ELSE
        RAISE NOTICE 'Result not ready yet';
    END IF;
END $$;

-- 6. Health monitoring
SELECT * FROM elixir_health();

-- 7. Function performance metrics (if available)
SELECT * FROM pg_elixir.function_stats ORDER BY call_count DESC;

-- 8. Safe function calls with error handling
SELECT pg_elixir.safe_call('add', '{"a": 100, "b": 200}'::jsonb);

-- 9. Hot code loading example
SELECT elixir_load_code('Calculator', '
defmodule Calculator do
  def fibonacci(0), do: 0
  def fibonacci(1), do: 1
  def fibonacci(n) when n > 1 do
    fibonacci(n - 1) + fibonacci(n - 2)
  end

  def factorial(0), do: 1
  def factorial(n) when n > 0 do
    n * factorial(n - 1)
  end
end
');

-- Now you can call the loaded functions
-- Note: You'll need to register these functions in the Elixir sidecar first

-- 10. Restart the Elixir process
SELECT elixir_restart();

-- 11. Cleanup old async results
SELECT pg_elixir.cleanup_old_results();

-- 12. Batch operations example
WITH batch_data AS (
  SELECT generate_series(1, 10) as num
)
SELECT
  num,
  elixir_call('multiply', json_build_object('a', num, 'b', num)::jsonb) as squared
FROM batch_data;

-- 13. Error handling example
DO $$
BEGIN
    PERFORM elixir_call('nonexistent_function', '{}'::jsonb);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Caught error: %', SQLERRM;
END $$;