CREATE TABLE IF NOT EXISTS node_logs (
    timestamp DateTime64(3),
    hostname String,
    unit String,
    priority UInt8,
    raw_log String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (hostname, timestamp)
TTL timestamp + INTERVAL 30 DAY DELETE;
