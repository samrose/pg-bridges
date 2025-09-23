-- pg_elixir Advanced Usage Examples

-- 1. Custom data processing pipeline
CREATE OR REPLACE FUNCTION process_user_data(user_data JSONB)
RETURNS JSONB AS $$
DECLARE
    processed_data JSONB;
    validation_result JSONB;
    enriched_data JSONB;
BEGIN
    -- Step 1: Validate the input data
    validation_result := elixir_call('validate_user_data', user_data);

    IF NOT (validation_result->>'valid')::boolean THEN
        RETURN json_build_object(
            'success', false,
            'error', validation_result->>'errors'
        );
    END IF;

    -- Step 2: Enrich the data with external services
    enriched_data := elixir_call('enrich_user_data', user_data);

    -- Step 3: Apply business logic transformations
    processed_data := elixir_call('transform_user_data', enriched_data);

    RETURN json_build_object(
        'success', true,
        'data', processed_data
    );
END;
$$ LANGUAGE plpgsql;

-- 2. Real-time analytics aggregation
CREATE OR REPLACE FUNCTION compute_realtime_metrics(
    start_time TIMESTAMPTZ,
    end_time TIMESTAMPTZ,
    metric_types TEXT[]
)
RETURNS TABLE(
    metric_name TEXT,
    value NUMERIC,
    computed_at TIMESTAMPTZ
) AS $$
DECLARE
    request_params JSONB;
    results JSONB;
    metric JSONB;
BEGIN
    request_params := json_build_object(
        'start_time', start_time,
        'end_time', end_time,
        'metric_types', metric_types
    );

    results := elixir_call('compute_metrics', request_params);

    FOR metric IN SELECT jsonb_array_elements(results->'metrics')
    LOOP
        metric_name := metric->>'name';
        value := (metric->>'value')::numeric;
        computed_at := NOW();
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 3. Machine Learning Pipeline Integration
CREATE OR REPLACE FUNCTION predict_user_behavior(
    user_features JSONB,
    model_name TEXT DEFAULT 'default_model'
)
RETURNS JSONB AS $$
DECLARE
    prediction_request JSONB;
    prediction_result JSONB;
BEGIN
    prediction_request := json_build_object(
        'features', user_features,
        'model', model_name,
        'version', 'latest'
    );

    -- Call Elixir ML service
    prediction_result := elixir_call('predict', prediction_request);

    -- Store prediction for audit trail
    INSERT INTO ml_predictions (
        user_id,
        features,
        model_name,
        prediction,
        confidence,
        created_at
    ) VALUES (
        (user_features->>'user_id')::int,
        user_features,
        model_name,
        prediction_result->'prediction',
        (prediction_result->>'confidence')::numeric,
        NOW()
    );

    RETURN prediction_result;
END;
$$ LANGUAGE plpgsql;

-- 4. Distributed Task Queue
CREATE TABLE task_queue (
    id SERIAL PRIMARY KEY,
    task_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    priority INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    result JSONB
);

CREATE OR REPLACE FUNCTION enqueue_task(
    task_type TEXT,
    payload JSONB,
    priority INTEGER DEFAULT 0
)
RETURNS INTEGER AS $$
DECLARE
    task_id INTEGER;
BEGIN
    INSERT INTO task_queue (task_type, payload, priority)
    VALUES (task_type, payload, priority)
    RETURNING id INTO task_id;

    -- Notify Elixir worker about new task
    PERFORM elixir_call_async('process_task', json_build_object(
        'task_id', task_id,
        'task_type', task_type,
        'payload', payload
    ));

    RETURN task_id;
END;
$$ LANGUAGE plpgsql;

-- 5. Complex Event Processing
CREATE OR REPLACE FUNCTION process_event_stream(events JSONB[])
RETURNS JSONB AS $$
DECLARE
    processing_request JSONB;
    results JSONB;
BEGIN
    processing_request := json_build_object(
        'events', array_to_json(events),
        'processing_rules', json_build_object(
            'window_size', '5 minutes',
            'aggregation_functions', array['count', 'sum', 'avg'],
            'correlation_rules', json_build_object(
                'time_window', '1 minute',
                'correlation_threshold', 0.8
            )
        )
    );

    results := elixir_call('process_event_stream', processing_request);

    -- Store results for further analysis
    INSERT INTO event_processing_results (
        batch_id,
        event_count,
        patterns_detected,
        anomalies,
        processed_at
    ) VALUES (
        gen_random_uuid(),
        array_length(events, 1),
        results->'patterns',
        results->'anomalies',
        NOW()
    );

    RETURN results;
END;
$$ LANGUAGE plpgsql;

-- 6. Monitoring and Alerting
CREATE OR REPLACE FUNCTION check_system_health()
RETURNS JSONB AS $$
DECLARE
    health_data JSONB;
    elixir_health JSONB;
    pg_stats JSONB;
    alert_data JSONB;
BEGIN
    -- Get Elixir sidecar health
    SELECT row_to_json(h) INTO elixir_health
    FROM elixir_health() h;

    -- Get PostgreSQL stats
    pg_stats := json_build_object(
        'connections', (SELECT count(*) FROM pg_stat_activity),
        'database_size', (SELECT pg_size_pretty(pg_database_size(current_database()))),
        'cache_hit_ratio', (
            SELECT round(
                100.0 * sum(blks_hit) / (sum(blks_hit) + sum(blks_read) + 1), 2
            )
            FROM pg_stat_database
        )
    );

    health_data := json_build_object(
        'elixir_sidecar', elixir_health,
        'postgresql', pg_stats,
        'timestamp', NOW()
    );

    -- Check for alerts
    alert_data := elixir_call('check_alerts', health_data);

    -- Send alerts if necessary
    IF alert_data->>'has_alerts' = 'true' THEN
        PERFORM elixir_call_async('send_alerts', alert_data);
    END IF;

    RETURN health_data;
END;
$$ LANGUAGE plpgsql;

-- 7. Data Transformation Pipeline
CREATE OR REPLACE FUNCTION transform_data_batch(
    input_table TEXT,
    output_table TEXT,
    transformation_config JSONB
)
RETURNS JSONB AS $$
DECLARE
    batch_size INTEGER := 1000;
    offset_val INTEGER := 0;
    total_processed INTEGER := 0;
    batch_data JSONB;
    transformed_data JSONB;
    sql_query TEXT;
BEGIN
    LOOP
        sql_query := format(
            'SELECT json_agg(row_to_json(t)) FROM (SELECT * FROM %I LIMIT %s OFFSET %s) t',
            input_table, batch_size, offset_val
        );

        EXECUTE sql_query INTO batch_data;

        EXIT WHEN batch_data IS NULL OR jsonb_array_length(batch_data) = 0;

        -- Transform the batch using Elixir
        transformed_data := elixir_call('transform_batch', json_build_object(
            'data', batch_data,
            'config', transformation_config
        ));

        -- Insert transformed data (this would need proper implementation)
        -- based on the actual output table structure

        total_processed := total_processed + jsonb_array_length(batch_data);
        offset_val := offset_val + batch_size;
    END LOOP;

    RETURN json_build_object(
        'status', 'completed',
        'total_processed', total_processed,
        'processed_at', NOW()
    );
END;
$$ LANGUAGE plpgsql;

-- 8. Usage examples for the advanced functions

-- Process some user data
SELECT process_user_data('{"user_id": 123, "email": "user@example.com", "age": 30}'::jsonb);

-- Compute real-time metrics
SELECT * FROM compute_realtime_metrics(
    NOW() - INTERVAL '1 hour',
    NOW(),
    ARRAY['user_signups', 'revenue', 'active_sessions']
);

-- Make a prediction
SELECT predict_user_behavior(
    '{"user_id": 456, "age": 25, "location": "US", "activity_score": 0.8}'::jsonb,
    'churn_prediction_v2'
);

-- Enqueue a background task
SELECT enqueue_task(
    'send_email',
    '{"recipient": "user@example.com", "template": "welcome", "data": {"name": "John"}}'::jsonb,
    10
);

-- Process a stream of events
SELECT process_event_stream(ARRAY[
    '{"type": "page_view", "user_id": 123, "page": "/home", "timestamp": "2024-01-01T10:00:00Z"}'::jsonb,
    '{"type": "click", "user_id": 123, "element": "signup_button", "timestamp": "2024-01-01T10:01:00Z"}'::jsonb,
    '{"type": "form_submit", "user_id": 123, "form": "registration", "timestamp": "2024-01-01T10:02:00Z"}'::jsonb
]);

-- Check system health
SELECT check_system_health();