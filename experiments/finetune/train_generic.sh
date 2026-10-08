#!/usr/bin/env bash
# usage: train_generic.sh TAG EXAMPLES_JSON [extra train_generic.py args]   -> adapter in ~/data/vsr/adapters/TAG, log ~/data/robot/results/train_TAG.log
set -euo pipefail
TAG="$1"; MIX="$2"; shift 2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; mkdir -p ~/data/robot/results ~/data/vsr/adapters
docker run --rm --gpus all --user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 -e HF_HOME=/tmp/hf -v /etc/passwd:/etc/passwd:ro \
  -v ~/models:/models -v ~/data:/data -v ~/data/robot:/robot -v "$HERE":/work vlm-finetune:dev \
  python train_generic.py --examples "/robot/$(basename "$MIX")" --out "/data/vsr/adapters/$TAG" "$@" 2>&1 | grep -v "Loading weights" | tee ~/data/robot/results/train_$TAG.log
