#!/usr/bin/env bash
# Send one chat request to a model on the iPhone and print the reply and speed.
# The app loads the model first if it is installed but not active.
#
# Usage:
#   bash scripts/iphone/try_model.sh MODEL_ID ["PROMPT"] [IMAGE.png|IMAGE.jpg]
#
# Needs the USB port forward (scripts/iphone/proxy.sh) and the API key in
# $API_KEY (source scripts/iphone/get_api_key.sh).
# Environment: PORT (default 8080), MAX_TOKENS (default 256), TEMPERATURE (default 0)
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 MODEL_ID [\"PROMPT\"] [IMAGE.png|IMAGE.jpg]" >&2
  exit 2
fi
if [ -z "${API_KEY:-}" ]; then
  echo "[ERROR] API_KEY is not set. Copy the key in the app, then: source scripts/iphone/get_api_key.sh" >&2
  exit 1
fi

model="$1"
prompt="${2:-Introduce yourself in one sentence.}"
image="${3:-}"
base_url="http://127.0.0.1:${PORT:-8080}"

if ! curl -fsS -m 5 "$base_url/health" >/dev/null 2>&1; then
  echo "[ERROR] The app does not answer on $base_url. Open the app and run: bash scripts/iphone/proxy.sh" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

MODEL="$model" PROMPT="$prompt" IMAGE="$image" python3 - > "$work_dir/request.json" <<'PY'
import base64, json, os, sys

content = os.environ["PROMPT"]
image = os.environ["IMAGE"]
if image:
    mime = "image/png" if image.lower().endswith(".png") else "image/jpeg"
    with open(image, "rb") as handle:
        data = base64.b64encode(handle.read()).decode()
    content = [
        {"type": "text", "text": content},
        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}},
    ]
json.dump({
    "model": os.environ["MODEL"],
    "messages": [{"role": "user", "content": content}],
    "max_tokens": int(os.environ.get("MAX_TOKENS", "256")),
    "temperature": float(os.environ.get("TEMPERATURE", "0")),
}, sys.stdout)
PY

# The key goes through a config file descriptor so it does not show up in the process list.
api() {
  curl --config <(printf 'header = "Authorization: Bearer %s"\n' "$API_KEY") -sS "$@"
}

status="$(api -m 600 -o "$work_dir/response.json" -w '%{http_code} %{time_total}' \
  -H 'Content-Type: application/json' -d @"$work_dir/request.json" "$base_url/v1/chat/completions")"
http_code="${status%% *}"
if [ "$http_code" != "200" ]; then
  echo "[ERROR] HTTP $http_code: $(jq -r '.error | "\(.type): \(.message)"' "$work_dir/response.json" 2>/dev/null)" >&2
  echo "        Load errors are explained in GET /logs and by: bash scripts/iphone/launch.sh $model" >&2
  exit 1
fi

jq -r '.choices[0].message.content' "$work_dir/response.json"
echo
api -m 10 "$base_url/metrics" | jq -r --arg total "${status##* }" '
  "[\(.model) on \(.backend)/\(.backend_runtime // "-")] total \($total)s, " +
  "first token \(.last_inference.ttft_milliseconds // 0 | floor) ms, " +
  "\(.last_inference.decode_tokens_per_second // 0 | . * 10 | floor / 10) tokens/s, " +
  "app memory \(.memory.physical_footprint_mb // 0 | floor) MB, thermal \(.thermal_state)"'
