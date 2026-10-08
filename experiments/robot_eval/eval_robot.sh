#!/usr/bin/env bash
# usage: eval_robot.sh TAG DATASET FORMAT [ADAPTER_DIR_IN_/data/vsr/adapters] [BASE_DIR_IN_/models/hf]  -> ~/data/robot/results/TAG_DATASET_FORMAT.json
set -euo pipefail
TAG="$1"; SET="$2"; FMT="$3"; AD="${4:-}"; BASE="${5:-gemma-4-E2B-it-qat}"; shift $(( $# > 5 ? 5 : $# )); EXTRA=("$@")
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; mkdir -p ~/data/robot/results
ARGS=(--data "/robot/$SET" --out "/robot/results/${TAG}_${SET}_${FMT}.json" --format "$FMT" --model "/models/hf/$BASE")
[ -n "$AD" ] && ARGS+=(--adapter "/data/vsr/adapters/$AD")
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 -e HF_HOME=/tmp/hf -v /etc/passwd:/etc/passwd:ro \
  -v ~/models:/models -v ~/data:/data -v ~/data/robot:/robot -v "$HERE":/work vlm-finetune:dev python eval_robot_hf.py "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | tail -1
