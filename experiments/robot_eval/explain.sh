#!/usr/bin/env bash
# usage: explain.sh TAG [ADAPTER_DIR_IN_/data/vsr/adapters]   -> ~/data/robot/results/explain_TAG.json
set -euo pipefail
TAG="$1"; AD="${2:-}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=("/robot/results/explain_${TAG}.json"); [ -n "$AD" ] && ARGS+=(--adapter "/data/vsr/adapters/$AD")
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 -e HF_HOME=/tmp/hf -v /etc/passwd:/etc/passwd:ro \
  -v ~/models:/models -v ~/data:/data -v ~/data/robot:/robot -v "$HERE":/work vlm-finetune:dev python explain_hf.py "${ARGS[@]}" 2>&1 | grep -v "Loading weights" | tail -3
