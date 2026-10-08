#!/usr/bin/env bash
# usage: eval_hf.sh TAG DATASET [ADAPTER_DIR_IN_/data/vsr/adapters] [BASE_DIR_IN_/models/hf]   -> ~/data/vsr/results/TAG_DATASET.json
set -euo pipefail
TAG="$1"; SET="$2"; AD="${3:-}"; BASE="${4:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=(--data "/data/vsr/$SET" --out "/data/vsr/results/${TAG}_${SET}.json")
[ -n "$AD" ] && ARGS+=(--adapter "/data/vsr/adapters/$AD")
[ -n "$BASE" ] && ARGS+=(--model "/models/hf/$BASE")
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 -e HF_HOME=/tmp/hf -v /etc/passwd:/etc/passwd:ro \
  -v ~/models:/models -v ~/data:/data -v "$HERE":/work vlm-finetune:dev python eval_hf.py "${ARGS[@]}" 2>&1 | tail -1
