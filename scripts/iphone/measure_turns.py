#!/usr/bin/env python3
"""Measure how many conversation turns fit in the context of the model on the iPhone.

Each turn resends the whole history, the way an OpenAI client does, and the script
reads the exact token counts the app reports in `usage`. It stops when the server
rejects the request (the prompt no longer fits) or after --max-turns.

Usage:
  python3 scripts/iphone/measure_turns.py MODEL_ID                       # text only
  python3 scripts/iphone/measure_turns.py MODEL_ID --image test.png      # an image in every turn

Needs the USB port forward (scripts/iphone/proxy.sh) and the API key in $API_KEY or in
~/.config/iphone-local-ai/api-key. The key is never printed.
Only the Python standard library is used.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

TEXT_PROMPTS = [
    "机の上の物の配置を日本語で説明してください。",
    "次に取るべき行動を1つ提案してください。",
    "その行動で注意すべき点は何ですか?",
    "今までの話を3行で要約してください。",
    "ロボットアームで安全に実行するための手順を考えてください。",
]
IMAGE_PROMPTS = [
    "今の状況を日本語で2文で説明してください。",
    "机の上にある物を列挙してください。",
    "前の画像と比べて変わった点はありますか?",
    "次に取るべき行動を1つ提案してください。",
]


def load_key() -> str:
    key = os.environ.get("API_KEY", "").strip()
    if not key:
        path = os.path.expanduser("~/.config/iphone-local-ai/api-key")
        if os.path.exists(path):
            key = open(path).read().strip()
    if not key:
        sys.exit("API key not found: set $API_KEY or write it to ~/.config/iphone-local-ai/api-key")
    return key


def call(base: str, key: str, path: str, body=None, timeout=900):
    request = urllib.request.Request(
        base + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.load(error)
        except Exception:
            return error.code, {"error": {"message": error.reason}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model")
    parser.add_argument("--image", help="PNG/JPEG sent with every turn (multimodal conversation)")
    parser.add_argument("--max-turns", type=int, default=60)
    parser.add_argument("--reply-tokens", type=int, default=150, help="max_tokens per reply (default 150)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    args = parser.parse_args()

    base = f"http://127.0.0.1:{args.port}"
    key = load_key()

    status, capabilities = call(base, key, "/capabilities")
    context = capabilities.get("context_tokens") if status == 200 else None
    status, metrics = call(base, key, "/metrics")
    print(f"model={args.model}  context_tokens={context}  "
          f"image={'yes: ' + args.image if args.image else 'no'}  reply_limit={args.reply_tokens}")
    if status == 200 and metrics.get("model") != args.model:
        print("(the model is loaded on the first request)")

    image_url = None
    if args.image:
        mime = "image/png" if args.image.lower().endswith(".png") else "image/jpeg"
        image_url = f"data:{mime};base64," + base64.b64encode(open(args.image, "rb").read()).decode()
    prompts = IMAGE_PROMPTS if image_url else TEXT_PROMPTS

    history = []
    rows = []
    print(f"{'turn':>4} {'prompt':>7} {'reply':>6} {'total':>6} {'+/turn':>7} {'time':>7}  finish")
    previous_total = 0
    for turn in range(1, args.max_turns + 1):
        text = prompts[(turn - 1) % len(prompts)]
        content = text if not image_url else [
            {"type": "text", "text": text},
            {"type": "image_url", "image_url": {"url": image_url}},
        ]
        history.append({"role": "user", "content": content})
        started = time.time()
        status, body = call(base, key, "/v1/chat/completions", {
            "model": args.model, "messages": history, "max_tokens": args.reply_tokens, "temperature": 0,
        })
        elapsed = time.time() - started
        if status != 200:
            message = body.get("error", {}).get("message", body)
            print(f"{turn:>4}  rejected (HTTP {status}): {message}")
            break
        usage = body["usage"]
        choice = body["choices"][0]
        history.append({"role": "assistant", "content": choice["message"]["content"]})
        total = usage["total_tokens"]
        rows.append((turn, usage["prompt_tokens"], usage["completion_tokens"], total, elapsed, choice["finish_reason"]))
        print(f"{turn:>4} {usage['prompt_tokens']:>7} {usage['completion_tokens']:>6} {total:>6} "
              f"{total - previous_total:>7} {elapsed:>6.1f}s  {choice['finish_reason']}")
        previous_total = total
        if choice["finish_reason"] == "length" and context and total >= context - 8:
            print(f"{turn:>4}  the context is full ({total}/{context} tokens)")
            break

    if not rows:
        return 1
    completed = len(rows)
    per_turn = (rows[-1][3] - rows[0][3]) / (completed - 1) if completed > 1 else rows[0][3]
    first_prompt = rows[0][1]
    print()
    print(f"turns that fit: {completed}")
    print(f"first turn prompt: {first_prompt} tokens;  growth per turn (user + reply): {per_turn:.0f} tokens")
    print(f"time of the first / last turn: {rows[0][4]:.1f}s / {rows[-1][4]:.1f}s "
          "(every turn evaluates the whole history again)")
    if context:
        print(f"estimate for other context sizes (same turn size): "
              + ", ".join(f"{size}: ~{max(0, int((size - first_prompt) / per_turn) + 1)} turns"
                          for size in (2048, 4096, 8192, 16384, 32768)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
