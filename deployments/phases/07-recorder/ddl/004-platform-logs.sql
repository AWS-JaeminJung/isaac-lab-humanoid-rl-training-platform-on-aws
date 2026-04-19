CREATE TABLE IF NOT EXISTS platform_logs (
    timestamp DateTime64(3),
    namespace String,
    pod_name String,
    container String,
    node String,
    raw_log String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (namespace, timestamp)
TTL timestamp + INTERVAL 30 DAY DELETE;
