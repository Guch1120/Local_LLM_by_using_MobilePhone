#!/usr/bin/env bash
# Load MODEL_ID on the phone and run base + two-step (and optionally thinking) on both samples.
# usage: run_model.sh MODEL_ID TAG [--think]       results: ~/data/vsr/results/TAG_*.json
set -uo pipefail
MODEL="$1"; TAG="$2"; THINK="${3:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; D=~/data/vsr; R=$D/results; mkdir -p "$R"
KEY=$(cat ~/.config/iphone-local-ai/api-key)
(cd "$REPO" && timeout 40 bash scripts/iphone/launch.sh "$MODEL" >/dev/null 2>&1)
for i in $(seq 1 60); do curl -s -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/capabilities | grep -q "\"$MODEL\"" && break; sleep 3; done
cd "$(dirname "${BASH_SOURCE[0]}")"
for S in 1 2; do
  python3 probe.py "$MODEL" "$R/${TAG}_base_$S.json" --data "$D/sample$S"
  python3 probe.py "$MODEL" "$R/${TAG}_twostep_$S.json" --data "$D/sample$S" --variant twostep
  [ -n "$THINK" ] && python3 probe.py "$MODEL" "$R/${TAG}_think_$S.json" --data "$D/sample$S" --think
done
python3 analyse.py "$R"/${TAG}_*.json
