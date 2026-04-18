#!/usr/bin/env python3
"""
hpo.py - Hyperparameter Optimization with Ray Tune + ASHA Scheduler

Runs a Ray Tune HPO sweep over learning_rate, gamma, and clip_param using
the ASHA (Async Successive Halving) scheduler for early stopping of
underperforming trials.

Usage:
    python hpo.py --task H1-v0 --num_trials 12 --max_concurrent 4 --gpus_per_trial 8

Environment variables:
    WORKFLOW_ID          - Unique workflow identifier for metrics grouping
    CLICKHOUSE_HOST      - ClickHouse hostname
    MLFLOW_TRACKING_URI  - MLflow tracking server URI
    CHECKPOINT_DIR       - Directory for checkpoint storage
"""

import argparse
import json
import os
import sys
import time
import uuid

import ray
from ray import tune
from ray.tune.schedulers import ASHAScheduler

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Isaac Lab HPO Script")
    parser.add_argument("--task", type=str, required=True, help="Task name (e.g., H1-v0)")
    parser.add_argument("--num_envs", type=int, default=4096, help="Number of parallel environments")
    parser.add_argument("--num_trials", type=int, default=12, help="Total number of HPO trials")
    parser.add_argument("--max_concurrent", type=int, default=4, help="Max concurrent trials")
    parser.add_argument("--gpus_per_trial", type=int, default=8, help="GPUs per trial")
    parser.add_argument("--max_iterations", type=int, default=200, help="Max iterations per trial")
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Training function (called by each Ray Tune trial)
# ---------------------------------------------------------------------------


def train_trial(config: dict, task: str, num_envs: int, max_iterations: int) -> None:
    """Single HPO trial training function."""
    workflow_id = os.environ.get("WORKFLOW_ID", "hpo-validation")
    trial_id = f"trial-{uuid.uuid4().hex[:8]}"
    sweep_id = config.get("sweep_id", f"sweep-{uuid.uuid4().hex[:8]}")

    # Initialize ClickHouse logger
    sys.path.insert(0, "/workspace/callbacks")
    try:
        from clickhouse_logger import ClickHouseLogger

        ch_logger = ClickHouseLogger(
            workflow_id=workflow_id,
            trial_id=trial_id,
            sweep_id=sweep_id,
            task=task,
        )
    except Exception as e:
        print(f"[hpo.py] ClickHouse logger init failed (non-fatal): {e}")
        ch_logger = None

    # Initialize MLflow
    try:
        import mlflow

        mlflow.set_experiment(f"isaac-lab/{task}/hpo")
        mlflow.start_run(run_name=f"{workflow_id}/{trial_id}", nested=True)
        mlflow.log_params({
            "learning_rate": config["learning_rate"],
            "gamma": config["gamma"],
            "clip_param": config["clip_param"],
            "task": task,
            "num_envs": num_envs,
            "trial_id": trial_id,
            "sweep_id": sweep_id,
        })
        mlflow_enabled = True
    except Exception:
        mlflow_enabled = False

    # Training loop for this trial
    learning_rate = config["learning_rate"]
    gamma = config["gamma"]
    clip_param = config["clip_param"]

    for iteration in range(1, max_iterations + 1):
        # Simulate training step (placeholder for actual Isaac Lab training)
        time.sleep(0.01)

        # Simulated metrics influenced by hyperparameters
        base_reward = 50.0 + (iteration / max_iterations) * 200.0
        lr_factor = 1.0 - abs(learning_rate - 3e-4) / 3e-4 * 0.3
        gamma_factor = 1.0 - abs(gamma - 0.99) / 0.1 * 0.2
        clip_factor = 1.0 - abs(clip_param - 0.2) / 0.2 * 0.1
        mean_reward = base_reward * lr_factor * gamma_factor * clip_factor
        policy_loss = 1.0 / (1.0 + iteration * learning_rate * 100)

        # Log to ClickHouse
        if ch_logger is not None:
            try:
                ch_logger.log_iteration(
                    iteration=iteration,
                    mean_reward=mean_reward,
                    policy_loss=policy_loss,
                    value_loss=policy_loss * 2.0,
                    entropy=0.5 * (1.0 - iteration / max_iterations),
                    fps=num_envs / 0.01,
                )
            except Exception:
                pass

        # Report to Ray Tune (for ASHA early stopping)
        tune.report(
            mean_reward=mean_reward,
            policy_loss=policy_loss,
            iteration=iteration,
        )

        # Log to MLflow periodically
        if mlflow_enabled and iteration % 10 == 0:
            try:
                mlflow.log_metrics({
                    "mean_reward": mean_reward,
                    "policy_loss": policy_loss,
                }, step=iteration)
            except Exception:
                pass

    # Flush and finalize
    if ch_logger is not None:
        ch_logger.flush()

    if mlflow_enabled:
        try:
            mlflow.log_metrics({"final_reward": mean_reward})
            mlflow.end_run()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Main HPO orchestration
# ---------------------------------------------------------------------------


def main() -> None:
    args = parse_args()

    workflow_id = os.environ.get("WORKFLOW_ID", f"hpo-{uuid.uuid4().hex[:8]}")

    print(f"[hpo.py] Starting HPO sweep")
    print(f"  Task:             {args.task}")
    print(f"  Num trials:       {args.num_trials}")
    print(f"  Max concurrent:   {args.max_concurrent}")
    print(f"  GPUs per trial:   {args.gpus_per_trial}")
    print(f"  Max iterations:   {args.max_iterations}")
    print(f"  Workflow ID:      {workflow_id}")

    # Initialize Ray (connect to existing cluster)
    ray.init(address="auto")

    # Define search space
    search_space = {
        "learning_rate": tune.loguniform(1e-5, 1e-2),
        "gamma": tune.uniform(0.9, 0.999),
        "clip_param": tune.uniform(0.1, 0.4),
        "sweep_id": workflow_id,
    }

    # ASHA scheduler for early stopping
    scheduler = ASHAScheduler(
        metric="mean_reward",
        mode="max",
        max_t=args.max_iterations,
        grace_period=20,
        reduction_factor=3,
    )

    # Run HPO sweep
    start_time = time.time()

    analysis = tune.run(
        tune.with_parameters(
            train_trial,
            task=args.task,
            num_envs=args.num_envs,
            max_iterations=args.max_iterations,
        ),
        config=search_space,
        num_samples=args.num_trials,
        max_concurrent_trials=args.max_concurrent,
        scheduler=scheduler,
        resources_per_trial={
            "cpu": 4,
            "gpu": args.gpus_per_trial,
        },
        verbose=1,
        name=f"hpo-{args.task}",
        storage_path=os.path.join(
            os.environ.get("CHECKPOINT_DIR", "/mnt/fsx/checkpoints"),
            workflow_id,
            "ray_results",
        ),
    )

    total_elapsed = time.time() - start_time

    # Print results
    best_trial = analysis.best_trial
    best_config = analysis.best_config
    best_reward = analysis.best_result["mean_reward"]

    print(f"\n[hpo.py] HPO sweep complete")
    print(f"  Total time:       {total_elapsed:.1f}s")
    print(f"  Trials completed: {len(analysis.trials)}")
    print(f"  Best reward:      {best_reward:.4f}")
    print(f"  Best config:")
    print(f"    learning_rate:  {best_config['learning_rate']:.6f}")
    print(f"    gamma:          {best_config['gamma']:.4f}")
    print(f"    clip_param:     {best_config['clip_param']:.4f}")

    # Save best config
    checkpoint_dir = os.environ.get("CHECKPOINT_DIR", "/mnt/fsx/checkpoints")
    best_config_path = os.path.join(checkpoint_dir, workflow_id, "best_config.json")
    os.makedirs(os.path.dirname(best_config_path), exist_ok=True)
    with open(best_config_path, "w") as f:
        json.dump({
            "task": args.task,
            "workflow_id": workflow_id,
            "best_reward": best_reward,
            "best_config": {
                "learning_rate": best_config["learning_rate"],
                "gamma": best_config["gamma"],
                "clip_param": best_config["clip_param"],
            },
            "num_trials": len(analysis.trials),
            "total_time_seconds": total_elapsed,
        }, f, indent=2)
    print(f"  Best config saved: {best_config_path}")

    ray.shutdown()


if __name__ == "__main__":
    main()
