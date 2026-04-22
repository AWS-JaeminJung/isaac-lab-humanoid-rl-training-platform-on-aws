#!/usr/bin/env python3
"""
train.py - Production Isaac Lab Training Script

Runs Isaac Lab training for a specified task with ClickHouse metrics logging,
MLflow experiment tracking, and FSx checkpoint storage.

Usage:
    python train.py --task H1-v0 --num_envs 4096 --max_iterations 100
    python -m torch.distributed.run --nproc_per_node=8 train.py --task H1-v0

Environment variables:
    WORKFLOW_ID          - Unique workflow identifier for metrics grouping
    CLICKHOUSE_HOST      - ClickHouse hostname (default: clickhouse.logging.svc.cluster.local)
    MLFLOW_TRACKING_URI  - MLflow tracking server URI
    CHECKPOINT_DIR       - Directory for checkpoint storage (default: /mnt/fsx/checkpoints)
"""

import argparse
import json
import os
import sys
import time
import uuid

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Isaac Lab Training Script")
    parser.add_argument("--task", type=str, required=True, help="Task name (e.g., H1-v0)")
    parser.add_argument("--num_envs", type=int, default=4096, help="Number of parallel environments")
    parser.add_argument("--max_iterations", type=int, default=1000, help="Maximum training iterations")
    parser.add_argument("--headless", action="store_true", help="Run without rendering")
    parser.add_argument("--device", type=str, default="cuda:0", help="Device (cuda:0, cuda, cpu)")
    parser.add_argument("--checkpoint_interval", type=int, default=100, help="Checkpoint every N iterations")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Main training loop
# ---------------------------------------------------------------------------


def main() -> None:
    args = parse_args()

    workflow_id = os.environ.get("WORKFLOW_ID", f"train-{uuid.uuid4().hex[:8]}")
    trial_id = os.environ.get("TRIAL_ID", f"trial-{uuid.uuid4().hex[:8]}")
    checkpoint_dir = os.environ.get("CHECKPOINT_DIR", "/mnt/fsx/checkpoints")

    print(f"[train.py] Starting training")
    print(f"  Task:            {args.task}")
    print(f"  Num envs:        {args.num_envs}")
    print(f"  Max iterations:  {args.max_iterations}")
    print(f"  Device:          {args.device}")
    print(f"  Workflow ID:     {workflow_id}")
    print(f"  Trial ID:        {trial_id}")
    print(f"  Checkpoint dir:  {checkpoint_dir}")

    # -----------------------------------------------------------------------
    # Initialize ClickHouse logger
    # -----------------------------------------------------------------------
    sys.path.insert(0, "/workspace/callbacks")
    from clickhouse_logger import ClickHouseLogger

    ch_logger = ClickHouseLogger(
        workflow_id=workflow_id,
        trial_id=trial_id,
        task=args.task,
    )

    # -----------------------------------------------------------------------
    # Initialize MLflow
    # -----------------------------------------------------------------------
    try:
        import mlflow

        mlflow.set_experiment(f"isaac-lab/{args.task}")
        mlflow.start_run(run_name=f"{workflow_id}/{trial_id}")
        mlflow.log_params({
            "task": args.task,
            "num_envs": args.num_envs,
            "max_iterations": args.max_iterations,
            "device": args.device,
            "seed": args.seed,
        })
        mlflow.set_tags({
            "task": args.task,
            "workflow_id": workflow_id,
            "trial_id": trial_id,
        })
        mlflow_enabled = True
        print("[train.py] MLflow tracking initialized")
    except Exception as e:
        print(f"[train.py] MLflow initialization failed (non-fatal): {e}")
        mlflow_enabled = False

    # -----------------------------------------------------------------------
    # Create checkpoint directory
    # -----------------------------------------------------------------------
    task_checkpoint_dir = os.path.join(checkpoint_dir, workflow_id, trial_id)
    os.makedirs(task_checkpoint_dir, exist_ok=True)

    # -----------------------------------------------------------------------
    # Training loop
    # -----------------------------------------------------------------------
    print(f"[train.py] Beginning training loop ({args.max_iterations} iterations)")
    start_time = time.time()

    for iteration in range(1, args.max_iterations + 1):
        iter_start = time.time()

        # Simulate training step (placeholder for actual Isaac Lab training)
        # In production, this would call the Isaac Lab environment step
        time.sleep(0.01)  # Placeholder

        # Simulated metrics (replace with actual training metrics)
        mean_reward = 50.0 + (iteration / args.max_iterations) * 200.0
        policy_loss = 1.0 / (1.0 + iteration * 0.01)
        value_loss = 2.0 / (1.0 + iteration * 0.005)
        entropy = 0.5 * (1.0 - iteration / args.max_iterations)

        iter_elapsed = time.time() - iter_start

        # Log to ClickHouse
        ch_logger.log_iteration(
            iteration=iteration,
            mean_reward=mean_reward,
            policy_loss=policy_loss,
            value_loss=value_loss,
            entropy=entropy,
            fps=args.num_envs / max(iter_elapsed, 0.001),
        )

        # Log to MLflow
        if mlflow_enabled and iteration % 10 == 0:
            try:
                mlflow.log_metrics({
                    "mean_reward": mean_reward,
                    "policy_loss": policy_loss,
                    "value_loss": value_loss,
                    "entropy": entropy,
                }, step=iteration)
            except Exception:
                pass

        # Checkpoint
        if iteration % args.checkpoint_interval == 0:
            ckpt_path = os.path.join(task_checkpoint_dir, f"checkpoint_{iteration:06d}.json")
            with open(ckpt_path, "w") as f:
                json.dump({
                    "iteration": iteration,
                    "mean_reward": mean_reward,
                    "workflow_id": workflow_id,
                    "trial_id": trial_id,
                    "task": args.task,
                }, f)
            print(f"[train.py] Checkpoint saved: {ckpt_path}")

        # Progress logging
        if iteration % 10 == 0 or iteration == args.max_iterations:
            elapsed = time.time() - start_time
            print(
                f"[train.py] Iteration {iteration}/{args.max_iterations} "
                f"| reward={mean_reward:.2f} | loss={policy_loss:.4f} "
                f"| elapsed={elapsed:.1f}s"
            )

    # -----------------------------------------------------------------------
    # Finalize
    # -----------------------------------------------------------------------
    total_elapsed = time.time() - start_time

    # Flush remaining ClickHouse metrics
    ch_logger.flush()

    # Log final metrics to MLflow
    if mlflow_enabled:
        try:
            mlflow.log_metrics({
                "final_reward": mean_reward,
                "total_iterations": args.max_iterations,
                "total_time_seconds": total_elapsed,
                "iterations_per_second": args.max_iterations / max(total_elapsed, 0.001),
            })
            mlflow.end_run()
        except Exception:
            pass

    print(f"[train.py] Training complete")
    print(f"  Total iterations:  {args.max_iterations}")
    print(f"  Total time:        {total_elapsed:.1f}s")
    print(f"  Iterations/sec:    {args.max_iterations / max(total_elapsed, 0.001):.2f}")
    print(f"  Final reward:      {mean_reward:.2f}")


if __name__ == "__main__":
    main()
