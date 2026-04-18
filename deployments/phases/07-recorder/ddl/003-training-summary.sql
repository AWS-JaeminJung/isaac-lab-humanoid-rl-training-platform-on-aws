CREATE TABLE IF NOT EXISTS training_summary (
    workflow_id String,
    sweep_id String,
    trial_id String,
    task String,
    started_at DateTime,
    finished_at DateTime,
    total_iterations UInt32,
    best_reward Float64,
    best_iteration UInt32,
    final_reward Float64,
    hp_learning_rate Float64,
    hp_gamma Float64,
    exit_code Int16
) ENGINE = MergeTree()
ORDER BY (started_at, workflow_id);
