CREATE TABLE IF NOT EXISTS training_raw_logs (
    timestamp DateTime64(3),
    workflow_id String,
    pod_name String,
    node String,
    raw_log String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (workflow_id, timestamp)
TTL timestamp + INTERVAL 90 DAY DELETE;
