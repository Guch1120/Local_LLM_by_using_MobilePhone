#!/usr/bin/env python3
"""Measure how many conversation turns fit in the context of the model on the iPhone.

Text mode plays one coherent robot conversation and checks, at intervals, that the
model still remembers what was said earlier. Each turn resends the whole history, the way an OpenAI client does, and the script
reads the exact token counts the app reports in `usage`. It stops when the server
rejects the request (the prompt no longer fits) or after --max-turns.

Usage:
  python3 scripts/iphone/measure_turns.py MODEL_ID                       # text only
  python3 scripts/iphone/measure_turns.py MODEL_ID --image test.png      # an image in every turn

A long run heats the phone, and the app then refuses requests (HTTP 503, thermal state
"serious"). The script says so instead of reporting it as a full context; with
--cooldown MINUTES it waits for the phone to cool down and retries the turn.

Needs the USB port forward (scripts/iphone/proxy.sh) and the API key in $API_KEY or in
~/.config/iphone-local-ai/api-key. The key is never printed.
Only the Python standard library is used.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Text mode plays one coherent conversation, so every answer depends on the earlier turns:
# a robot is told to tidy away objects; some turns ask what was said before and are checked
# automatically (the reply must contain the expected words).
SCENARIO = ("あなたは家庭用ロボットの行動計画担当です。机の上には赤い皿、赤いマグカップ、緑のコップがあります。"
            "ユーザーの指示は「緑のコップを棚に片付けて」です。手順を3ステップで簡潔に答えてください。")
NEW_ITEMS = ["青い箱", "黄色いボール", "白いカップ", "黒いノート", "紫のペン", "茶色の袋", "銀色のスプーン", "橙色のタオル"]


def text_turn(turn):
    """Returns (prompt, expected words in the reply or None)."""
    if turn == 1:
        return SCENARIO, None
    k = turn - 2
    kind = k % 4
    if kind == 0:
        item = NEW_ITEMS[(k // 4) % len(NEW_ITEMS)]
        return f"追加の指示です。{item}も棚に片付けてください。さっきの手順を更新してください。", None
    if kind == 1:
        return "最初に私が片付けるよう指示した物は何でしたか?一言で答えてください。", ["緑のコップ"]
    if kind == 2:
        return "安全上の注意点を2つだけ挙げてください。", None
    return "机の上に最初にあった物をすべて挙げてください。", ["赤い皿", "赤いマグカップ", "緑のコップ"]


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


def battery_temperature():
    """Battery temperature in degrees Celsius, read by the PC over USB (None when unavailable).

    iOS gives apps no temperature in degrees; the battery sensor is the closest number. The chip
    that runs the model is hotter than the battery.
    """
    try:
        output = subprocess.run(["pymobiledevice3", "diagnostics", "battery", "single"],
                                capture_output=True, text=True, timeout=30).stdout
        return json.loads(output)["Temperature"] / 100
    except Exception:
        return None


def wait_for_cooldown(base: str, key: str, minutes: float) -> float:
    """Poll /metrics until the thermal state is nominal or fair. Returns the seconds waited."""
    started = time.time()
    print(f"      phone is hot - waiting up to {minutes:g} min for it to cool down ...", flush=True)
    while time.time() - started < minutes * 60:
        time.sleep(15)
        status, metrics = call(base, key, "/metrics", timeout=30)
        if status == 200 and metrics.get("thermal_state") in ("nominal", "fair"):
            break
    return time.time() - started


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model")
    parser.add_argument("--image", help="PNG/JPEG sent with every turn (multimodal conversation)")
    parser.add_argument("--max-turns", type=int, default=60)
    parser.add_argument("--reply-tokens", type=int, default=150, help="max_tokens per reply (default 150)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    parser.add_argument("--cooldown", type=float, default=0, metavar="MINUTES",
                        help="wait up to this long for the phone to cool down after a thermal stop, then retry")
    parser.add_argument("--save", metavar="FILE", help="write the conversation and the per-turn numbers as JSON")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # show each turn at once, also through a pipe

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
    prompts = IMAGE_PROMPTS
    recall_hits = recall_total = 0

    history = []
    rows = []
    stopped_by = "max-turns"
    cached_total = prompt_total = 0
    cooled_seconds = 0.0
    print(f"{'turn':>4} {'prompt':>7} {'reply':>6} {'total':>6} {'+/turn':>7} {'time':>7} {'battery':>8}  {'heat':<8} {'tok/s':>6} {'cached':>7} finish")
    previous_total = 0
    temperatures = [t for t in [battery_temperature()] if t is not None]
    if temperatures:
        print(f"      battery temperature before the first turn: {temperatures[0]:.1f} C")
    for turn in range(1, args.max_turns + 1):
        expected = None
        if image_url:
            text = prompts[(turn - 1) % len(prompts)]
        else:
            text, expected = text_turn(turn)
        content = text if not image_url else [
            {"type": "text", "text": text},
            {"type": "image_url", "image_url": {"url": image_url}},
        ]
        history.append({"role": "user", "content": content})
        while True:
            started = time.time()
            status, body = call(base, key, "/v1/chat/completions", {
                "model": args.model, "messages": history, "max_tokens": args.reply_tokens, "temperature": 0,
            })
            elapsed = time.time() - started
            message = str(body.get("error", {}).get("message", "")) if status != 200 else ""
            if status == 503 and "thermal" in message.lower() and args.cooldown > 0:
                waited = wait_for_cooldown(base, key, args.cooldown)
                cooled_seconds += waited
                if waited < args.cooldown * 60:
                    continue
            break
        if status != 200:
            print(f"{turn:>4}  rejected (HTTP {status}): {message or body}")
            if "thermal" in message.lower():
                stopped_by = "thermal"
            elif "context" in message.lower() or "tokens" in message.lower():
                stopped_by = "context"
            else:
                stopped_by = "error"
            break
        usage = body["usage"]
        choice = body["choices"][0]
        history.append({"role": "assistant", "content": choice["message"]["content"]})
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
        recall = ""
        if usage["completion_tokens"] == 0 and choice["finish_reason"] == "stop":
            recall = "  EMPTY REPLY"
        if expected:
            ok = all(word in choice["message"]["content"] for word in expected)
            recall_total += 1
            recall_hits += ok
            recall = "  recall OK" if ok else "  recall WRONG"
        total = usage["total_tokens"]
        rows.append((turn, usage["prompt_tokens"], usage["completion_tokens"], total, elapsed, choice["finish_reason"]))
        cached_total += (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
        prompt_total += usage["prompt_tokens"]
        celsius = battery_temperature()
        if celsius is not None:
            temperatures.append(celsius)
        _, latest = call(base, key, "/metrics", timeout=30)
        heat = str(latest.get("thermal_state", "-")) if isinstance(latest, dict) else "-"
        speed = (latest.get("last_inference") or {}).get("decode_tokens_per_second") if isinstance(latest, dict) else None
        battery = f"{celsius:.1f}C" if celsius is not None else "-"
        print(f"{turn:>4} {usage['prompt_tokens']:>7} {usage['completion_tokens']:>6} {total:>6} "
              f"{total - previous_total:>7} {elapsed:>6.1f}s {battery:>8}  {heat:<8} "
              f"{(f'{speed:.1f}' if speed else '-'):>6} {cached:>7} {choice['finish_reason']}{recall}")
        previous_total = total
        if choice["finish_reason"] == "length" and context and total >= context - 8:
            print(f"{turn:>4}  the context is full ({total}/{context} tokens)")
            stopped_by = "context"
            break

    if not rows:
        return 1
    completed = len(rows)
    if args.save:
        with open(args.save, "w") as out:
            json.dump({"model": args.model, "context_tokens": context, "stopped_by": stopped_by,
                       "turns": [dict(zip(("turn", "prompt", "reply", "total", "seconds", "finish"), r)) for r in rows],
                       "messages": [m if isinstance(m["content"], str) else
                                    {"role": m["role"], "content": m["content"][0]["text"] + " [+image]"}
                                    for m in history]}, out, ensure_ascii=False, indent=1)
    per_turn = (rows[-1][3] - rows[0][3]) / (completed - 1) if completed > 1 else rows[0][3]
    first_prompt = rows[0][1]
    print()
    reasons = {
        "context": "the context was full",
        "thermal": "the phone got too hot and the app paused inference (not a context limit)",
        "error": "the server returned an error",
        "max-turns": "--max-turns was reached",
    }
    print(f"turns completed: {completed}  (stopped: {reasons[stopped_by]})")
    if context:
        print(f"context used at the last turn: {rows[-1][3]}/{context} tokens")
    if prompt_total:
        print(f"prompt tokens served from the KV cache: {cached_total}/{prompt_total} ({100 * cached_total / prompt_total:.0f}%)")
    if recall_total:
        print(f"recall questions answered correctly: {recall_hits}/{recall_total} "
              "(what was said in earlier turns, checked automatically)")
    if temperatures:
        print(f"battery temperature: {temperatures[0]:.1f} C at the start, up to {max(temperatures):.1f} C "
              f"(+{max(temperatures) - temperatures[0]:.1f} C) - measured on the battery, the chip is hotter")
    if cooled_seconds:
        print(f"waited {cooled_seconds / 60:.1f} min for the phone to cool down (not counted in the times)")
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
