"""
clickhouse_logger.py - ClickHouse Training Metrics Logger

Batch-inserts training metrics into ClickHouse every N iterations for
fault-tolerant, high-throughput metrics logging during Isaac Lab training.

Usage:
    from clickhouse_logger import ClickHouseLogger

    logger = ClickHouseLogger(workflow_id="my-run", trial_id="trial-0", task="H1-v0")
    logger.log_iteration(iteration=1, mean_reward=42.0, policy_loss=0.5)
    logger.flush()  # Flush remaining buffered rows

Environment variables:
    CLICKHOUSE_HOST     - ClickHouse hostname (default: clickhouse.logging.svc.cluster.local)
    CLICKHOUSE_PORT     - ClickHouse HTTP port (default: 8123)
    CLICKHOUSE_DATABASE - ClickHouse database name (default: default)
"""

import os
import time
from datetime import datetime, timezone
from typing import Any, Optional


class ClickHouseLogger:
    """Batch logger for ClickHouse training_metrics table."""

    def __init__(
        self,
        workflow_id: str,
        trial_id: str,
        task: str,
        sweep_id: str = "",
        batch_size: int = 10,
        table: str = "training_metrics",
    ) -> None:
        self.workflow_id = workflow_id
        self.trial_id = trial_id
        self.task = task
        self.sweep_id = sweep_id
        self.batch_size = batch_size
        self.table = table

        self._buffer: list[dict[str, Any]] = []
        self._client: Optional[Any] = None
        self._init_failed = False

        # Initialize ClickHouse client
        try:
            import clickhouse_connect

            self._client = clickhouse_connect.get_client(
                host=os.environ.get("CLICKHOUSE_HOST", "clickhouse.logging.svc.cluster.local"),
                port=int(os.environ.get("CLICKHOUSE_PORT", "8123")),
                database=os.environ.get("CLICKHOUSE_DATABASE", "default"),
            )
        except Exception as e:
            print(f"[ClickHouseLogger] Connection failed (non-fatal): {e}")
            self._init_failed = True

    def log_iteration(
        self,
        iteration: int,
        mean_reward: float = 0.0,
        policy_loss: float = 0.0,
        value_loss: float = 0.0,
        entropy: float = 0.0,
        fps: float = 0.0,
        **extra_metrics: float,
    ) -> None:
        """Buffer a single iteration's metrics. Flushes every batch_size rows."""
        row = {
            "timestamp": datetime.now(timezone.utc),
            "workflow_id": self.workflow_id,
            "trial_id": self.trial_id,
            "sweep_id": self.sweep_id,
            "task": self.task,
            "iteration": iteration,
            "mean_reward": mean_reward,
            "policy_loss": policy_loss,
            "value_loss": value_loss,
            "entropy": entropy,
            "fps": fps,
        }
        row.update(extra_metrics)
        self._buffer.append(row)

        if len(self._buffer) >= self.batch_size:
            self.flush()

    def flush(self) -> None:
        """Insert buffered rows into ClickHouse. Silently drops on failure."""
        if not self._buffer:
            return

        if self._init_failed or self._client is None:
            self._buffer.clear()
            return

        try:
            columns = [
                "timestamp",
                "workflow_id",
                "trial_id",
                "sweep_id",
                "task",
                "iteration",
                "mean_reward",
                "policy_loss",
                "value_loss",
                "entropy",
                "fps",
            ]

            data = []
            for row in self._buffer:
                data.append([row.get(col, "") for col in columns])

            self._client.insert(
                self.table,
                data,
                column_names=columns,
            )

            self._buffer.clear()

        except Exception as e:
            # Fault tolerance: log the error but do not crash training
            print(f"[ClickHouseLogger] Flush failed (non-fatal, {len(self._buffer)} rows dropped): {e}")
            self._buffer.clear()

    def close(self) -> None:
        """Flush remaining buffer and close the client."""
        self.flush()
        if self._client is not None:
            try:
                self._client.close()
            except Exception:
                pass

    def __del__(self) -> None:
        """Ensure buffer is flushed on garbage collection."""
        try:
            self.flush()
        except Exception:
            pass
