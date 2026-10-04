#!/usr/bin/env python3
"""Measure how a long history costs: the first request, and the next turn that continues it.

For each size it builds a conversation of about that many prompt tokens (filler text the model has
to read, with one fact planted at the start), sends it once, then sends the same conversation plus the
model's reply and a new question. With the KV cache the second request evaluates only the new tokens;
without it, the whole history again. The reply to the second question is checked for the planted fact.

Usage:
  python3 scripts/iphone/measure_context.py MODEL_ID 2000 8000 30000
  python3 scripts/iphone/measure_context.py MODEL_ID 8000 --label no-cache     # label for the output file
  python3 scripts/iphone/measure_context.py MODEL_ID 8000 --save result.json

The context size of the loaded model must be larger than the sizes you ask for (Settings, or the launch
argument `-contextTokens 32768`). Needs the USB port forward (proxy.sh) and the API key in $API_KEY or
~/.config/iphone-local-ai/api-key. Only the Python standard library is used.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

PARAGRAPHS = [
    "倉庫の第{n}区画では、朝の点検で棚の固定ボルトとラベルの向きを確認します。記録は共有シートに入力し、異常があれば担当者に連絡します。",
    "搬送ルート{n}は幅が狭いため、ロボットは時速0.5メートル以下で走行します。人が近づいたら一時停止し、通過を待ってから再開します。",
    "在庫カウントは毎週{n}曜日に実施します。数量の差異が3個以上ある場合は再カウントを行い、原因を調べてから報告書にまとめます。",
    "荷物の積み上げは最大{n}段までとし、重い物を下に置きます。崩れ防止のため、段ごとに滑り止めシートを敷いてください。",
    "夜間の巡回では非常口の前に物が置かれていないかを確認します。見つけた場合はその場で移動し、巡回記録に時刻を書き残します。",
]
FACT = "最初に大事なことを伝えます。合言葉は「青いキツネ」です。覚えておいてください。"
ACK = "了解しました。"
QUESTION = "最初に私が伝えた合言葉は何でしたか?合言葉だけを答えてください。"


def key() -> str:
    value = os.environ.get("API_KEY", "").strip()
    if not value:
        path = os.path.expanduser("~/.config/iphone-local-ai/api-key")
        if os.path.exists(path):
            value = open(path).read().strip()
    if not value:
        sys.exit("API key not found: set $API_KEY or write it to ~/.config/iphone-local-ai/api-key")
    return value


def call(base, api_key, path, body=None, timeout=3600):
    request = urllib.request.Request(
        base + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.load(error)
        except Exception:
            return error.code, {"error": {"message": error.reason}}


def battery_celsius():
    try:
        output = subprocess.run(["pymobiledevice3", "diagnostics", "battery", "single"],
                                capture_output=True, text=True, timeout=30).stdout
        return json.loads(output)["Temperature"] / 100
    except Exception:
        return None


def build(filler: int, final_question: str):
    messages = [{"role": "user", "content": FACT}, {"role": "assistant", "content": ACK}]
    for i in range(filler):
        messages.append({"role": "user", "content": PARAGRAPHS[i % 5].format(n=i + 1) + "読んだら「了解しました」とだけ答えてください。"})
        messages.append({"role": "assistant", "content": ACK})
    messages.append({"role": "user", "content": final_question})
    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model")
    parser.add_argument("sizes", type=int, nargs="+", help="prompt sizes in tokens, for example 2000 8000 30000")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    parser.add_argument("--label", default="", help="a note printed with the results, e.g. cache-on")
    parser.add_argument("--save", metavar="FILE")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)

    base = f"http://127.0.0.1:{args.port}"
    api_key = key()
    status, capabilities = call(base, api_key, "/capabilities", timeout=30)
    context = capabilities.get("context_tokens") if status == 200 else None
    print(f"model={args.model} context_tokens={context} {args.label}")
    print(f"{'target':>7} {'prompt':>7} {'1st request':>12} {'cached':>7} {'2nd request':>12} {'cached':>7} "
          f"{'speedup':>8} {'battery':>8} {'heat':<8} recall")

    # A request a few tokens long to find the size of one paragraph, then scale.
    results = []
    for target in args.sizes:
        if context and target + 300 > context:
            print(f"{target:>7}  skipped: the context ({context}) is too small for it")
            continue
        # The size of a paragraph is learned from a short request that starts differently from the real
        # one, so that it leaves nothing in the KV cache that the real request could reuse.
        probe_messages = [{"role": "user", "content": f"サイズ確認{target}"}] + build(20, "ok")[1:]
        status, probe = call(base, api_key, "/v1/chat/completions",
                             {"model": args.model, "messages": probe_messages, "max_tokens": 1, "temperature": 0})
        if status != 200:
            print(f"{target:>7}  probe failed: {probe.get('error', {}).get('message', probe)}")
            continue
        per_paragraph = max(1.0, (probe["usage"]["prompt_tokens"] - 40) / 20)
        filler = max(1, int((target - 60) / per_paragraph))

        first_messages = build(filler, "ここまでで私が伝えた合言葉を、一言で答えてください。")
        # A request that shares no start with the real one: the KV cache then holds nothing useful for it.
        call(base, api_key, "/v1/chat/completions",
             {"model": args.model, "messages": [{"role": "user", "content": f"キャッシュを空にする{target}"}],
              "max_tokens": 1, "temperature": 0})
        started = time.time()
        status, first = call(base, api_key, "/v1/chat/completions",
                             {"model": args.model, "messages": first_messages, "max_tokens": 24, "temperature": 0})
        first_seconds = time.time() - started
        if status != 200:
            print(f"{target:>7}  rejected: {first.get('error', {}).get('message', first)}")
            continue
        reply = first["choices"][0]["message"]["content"]

        second_messages = first_messages + [{"role": "assistant", "content": reply},
                                            {"role": "user", "content": QUESTION}]
        started = time.time()
        status, second = call(base, api_key, "/v1/chat/completions",
                              {"model": args.model, "messages": second_messages, "max_tokens": 24, "temperature": 0})
        second_seconds = time.time() - started
        if status != 200:
            print(f"{target:>7}  second request rejected: {second.get('error', {}).get('message', second)}")
            continue
        answer = second["choices"][0]["message"]["content"]
        _, metrics = call(base, api_key, "/metrics", timeout=30)
        heat = metrics.get("thermal_state", "-") if isinstance(metrics, dict) else "-"
        celsius = battery_celsius()
        cached1 = first["usage"].get("prompt_tokens_details", {}).get("cached_tokens", 0)
        cached2 = second["usage"].get("prompt_tokens_details", {}).get("cached_tokens", 0)
        recall = "OK" if "青いキツネ" in answer else f"WRONG ({answer.strip()[:30]!r})"
        speedup = first_seconds / second_seconds if second_seconds else 0
        print(f"{target:>7} {first['usage']['prompt_tokens']:>7} {first_seconds:>11.1f}s {cached1:>7} {second_seconds:>11.1f}s "
              f"{cached2:>7} {speedup:>7.1f}x {(f'{celsius:.1f}C' if celsius else '-'):>8} {heat:<8} {recall}")
        results.append({
            "target": target, "prompt_tokens": first["usage"]["prompt_tokens"],
            "first_seconds": first_seconds, "first_cached": cached1,
            "second_seconds": second_seconds, "second_cached": cached2,
            "battery_c": celsius, "heat": heat, "recall": recall, "answer": answer,
        })

    if args.save:
        with open(args.save, "w") as out:
            json.dump({"model": args.model, "context_tokens": context, "label": args.label, "results": results}, out,
                      ensure_ascii=False, indent=1)
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
