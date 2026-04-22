################################################################################
# Production Training Image for Isaac Lab
#
# Based on NVIDIA Isaac Lab 2.2.0 with Ray, ClickHouse logging, MLflow
# tracking, and S3/FSx checkpoint support.
#
# Build:
#   docker build -t isaac-lab-training:v1.0.0 .
#
# Run (local test):
#   docker run --gpus all isaac-lab-training:v1.0.0 \
#     python /workspace/scripts/train.py --task H1-v0 --max_iterations 10
################################################################################
FROM nvcr.io/nvidia/isaac-lab:2.2.0

# ---------------------------------------------------------------------------
# Install Python dependencies
# ---------------------------------------------------------------------------
RUN pip install --no-cache-dir \
    ray[default]==2.42.1 \
    clickhouse-connect \
    mlflow \
    boto3

# ---------------------------------------------------------------------------
# Copy training scripts and callbacks
# ---------------------------------------------------------------------------
COPY scripts/ /workspace/scripts/
COPY callbacks/ /workspace/callbacks/

# ---------------------------------------------------------------------------
# Environment defaults (overridable at runtime)
# ---------------------------------------------------------------------------
ENV CLICKHOUSE_HOST=clickhouse.logging.svc.cluster.local
ENV CLICKHOUSE_PORT=8123
ENV CLICKHOUSE_DATABASE=default
ENV MLFLOW_TRACKING_URI=http://mlflow.model-registry.svc.cluster.local:5000
ENV CHECKPOINT_DIR=/mnt/fsx/checkpoints
ENV PYTHONUNBUFFERED=1

# ---------------------------------------------------------------------------
# Default working directory
# ---------------------------------------------------------------------------
WORKDIR /workspace
