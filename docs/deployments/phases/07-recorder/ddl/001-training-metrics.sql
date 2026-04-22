CREATE TABLE IF NOT EXISTS training_metrics (
    timestamp DateTime64(3),
    workflow_id String,
    trial_id String,
    sweep_id String,
    task String,
    iteration UInt32,
    mean_reward Float64,
    episode_length Float64,
    base_contact Float64,
    time_out_pct Float64,
    value_loss Float64,
    policy_loss Float64,
    entropy Float64,
    kl_divergence Float64,
    learning_rate_actual Float64,
    grad_norm Float64,
    reward_tracking Float64,
    reward_lin_vel Float64,
    reward_ang_vel Float64,
    reward_joint_acc Float64,
    reward_feet_air Float64,
    iteration_time Float64,
    collection_time Float64,
    learning_time Float64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (workflow_id, trial_id, iteration)
TTL timestamp + INTERVAL 180 DAY DELETE;
