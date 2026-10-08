# Shared helpers for phone experiments: source this file.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VSR="$REPO/experiments/vsr"; D=~/data/vsr; R=$D/results
KEY=$(cat ~/.config/iphone-local-ai/api-key)
# load_model MODEL_ID [APP_ARGS]  -- relaunch the app with that model (and optional launch arguments) and wait until it answers
load_model() {
  (cd "$REPO" && APP_ARGS="${2:-}" timeout 45 bash scripts/iphone/launch.sh "$1" >/dev/null 2>&1)
  for i in $(seq 1 80); do
    curl -s -m 120 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' http://127.0.0.1:8080/v1/chat/completions \
      -d "{\"model\":\"$1\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" | grep -q '"choices"' && return 0
    sleep 5
  done
  echo "model $1 did not load" >&2; return 1
}
# probe MODEL TAG SAMPLE [extra probe.py args]  -> $R/TAG_SAMPLE.json
probe() { local m="$1" t="$2" s="$3"; shift 3; (cd "$VSR" && timeout 14400 python3 probe.py "$m" "$R/${t}_${s}.json" --data "$D/$s" "$@" | head -2); }
