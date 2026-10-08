#!/usr/bin/env bash
# usage: eval_robofac_variants.sh TAG [ADAPTER_DIR_IN_/data/vsr/adapters] [extra eval args]   -> ~/data/robot/results/TAG_variants.json
set -euo pipefail
TAG="$1"; AD="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; mkdir -p ~/data/robot/results
ARGS=(--out "/robot/results/${TAG}_variants.json")
[ -n "$AD" ] && ARGS+=(--adapter "/data/vsr/adapters/$AD")
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 -e HF_HOME=/tmp/hf -v /etc/passwd:/etc/passwd:ro \
  -v ~/models:/models -v ~/data:/data -v ~/data/robot:/robot -v "$HERE":/work vlm-finetune:dev python eval_robofac_variants.py "${ARGS[@]}" "$@"
