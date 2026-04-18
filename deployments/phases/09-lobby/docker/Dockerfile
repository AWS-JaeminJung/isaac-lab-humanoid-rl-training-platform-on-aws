################################################################################
# JupyterHub Notebook Image
#
# Custom notebook environment for Isaac Lab researchers. Based on the
# jupyter/scipy-notebook image with additional Python packages for:
#   - OSMO training submission (osmo-client)
#   - ClickHouse querying (clickhouse-connect)
#   - Experiment tracking (mlflow)
#   - AWS integration (boto3)
#   - Data visualization (plotly, matplotlib, ipywidgets)
#   - Data analysis (pandas)
################################################################################

FROM jupyter/scipy-notebook:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl jq && rm -rf /var/lib/apt/lists/*
USER ${NB_UID}

RUN pip install --no-cache-dir \
    osmo-client \
    clickhouse-connect \
    mlflow \
    boto3 \
    plotly \
    ipywidgets \
    pandas \
    matplotlib
