"""RoboSpatial-Home (yes/no) and ERQA (multiple choice) through the phone's API, with the same prompts as eval_robot_hf.py (native format).

usage: probe_robot_phone.py MODEL OUT.json --data ~/robot_data/erqa [--limit N]
  yes/no   : score = log p(yes) - log p(no) at the first answer token; accuracy at 0 and ROC-AUC
  multiple : the option letter with the highest probability at the first answer token
The API key is read from ~/.config/iphone-local-ai/api-key; the phone must be forwarded to 127.0.0.1:8080.
"""
import argparse, base64, json, math, os, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("out"); ap.add_argument("--data", required=True)
ap.add_argument("--limit", type=int, default=10**9)
ap.add_argument("--types", default="", help="comma-separated type prefixes to keep, e.g. detection or identification,locating")
a = ap.parse_args()
KEY = open(os.path.expanduser("~/.config/iphone-local-ai/api-key")).read().strip()


def call(body):
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    for attempt in range(3):  # the app can be busy or restarting; do not lose a long run to one failure
        try:
            return json.load(urllib.request.urlopen(req, timeout=600))
        except Exception:
            if attempt == 2:
                raise
            time.sleep(15)


def first_token_mass(choice, names):
    """Probability mass of each wanted word at the first generated token (case and leading space ignored)."""
    mass = {n: 0.0 for n in names}
    for c in choice["logprobs"]["content"][0]["top_logprobs"]:
        key = c["token"].strip().strip('"').strip(".").lower()
        if key in mass:
            mass[key] += math.exp(c["logprob"])
    return mass


def ask(item):
    content = []
    for name in item["images"]:
        data = base64.b64encode(open(f"{a.data}/images/{name}", "rb").read()).decode()
        content.append({"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + data}})
    text = item["question"] + (" Answer yes or no." if item["kind"] == "yesno" else "")
    content.append({"type": "text", "text": text})
    return call({"model": a.model, "temperature": 0, "max_tokens": 2, "logprobs": True, "top_logprobs": 10,
                 "chat_template_kwargs": {"enable_thinking": False},
                 "messages": [{"role": "user", "content": content}]})


def auc(rows):
    pos = [r["score"] for r in rows if r["answer"] == "yes"]
    neg = [r["score"] for r in rows if r["answer"] == "no"]
    return sum((p > n) + 0.5 * (p == n) for p in pos for n in neg) / (len(pos) * len(neg)) if pos and neg else float("nan")


items = json.load(open(f"{a.data}/usable.json"))
if a.types:
    keep = tuple(a.types.split(","))
    items = [i for i in items if (i.get("type") or "").startswith(keep)]
items = items[:a.limit]
results, seconds, missing = [], [], 0
for item in items:
    try:
        t0 = time.time(); d = ask(item); seconds.append(time.time() - t0)
        choice = d["choices"][0]
        if item["kind"] == "yesno":
            m = first_token_mass(choice, ["yes", "no"])
            if m["yes"] + m["no"] == 0:
                missing += 1; continue
            r = {"score": math.log(max(m["yes"], 1e-9)) - math.log(max(m["no"], 1e-9))}
        else:
            letters = [c for c in "ABCDEFGH" if f"{c}." in item["question"] or f"({c})" in item["question"]] or list("ABCD")
            m = first_token_mass(choice, [c.lower() for c in letters])
            if sum(m.values()) == 0:
                missing += 1; continue
            r = {"choice": max(m, key=m.get).upper()}
    except Exception:
        missing += 1; continue
    r.update({"id": item["id"], "kind": item["kind"], "type": item.get("type"), "answer": item["answer"]})
    results.append(r)
    if len(results) % 100 == 0:
        json.dump({"partial": True, "results": results}, open(a.out + ".partial", "w"))


def correct(r):
    return (r["score"] > 0) == (r["answer"] == "yes") if r["kind"] == "yesno" else r["choice"] == r["answer"]


n = len(results)
summary = {"model": a.model, "data": os.path.basename(a.data.rstrip("/")), "n": n, "missing": missing,
           "accuracy": round(sum(map(correct, results)) / max(1, n), 3), "seconds_per_q": round(sum(seconds) / max(1, len(seconds)), 2),
           "median_seconds_per_q": round(sorted(seconds)[len(seconds) // 2], 2) if seconds else None}
if results and results[0]["kind"] == "yesno":
    summary["auc"] = round(auc(results), 3)
    summary["says_yes"] = round(sum(r["score"] > 0 for r in results) / n, 3)
else:
    types = sorted({r["type"] for r in results if r["type"]})
    summary["by_type"] = {t: [sum(map(correct, p)) / len(p), len(p)] for t in types for p in [[r for r in results if r["type"] == t]]}
json.dump({"summary": summary, "results": results}, open(a.out, "w"))
print(json.dumps(summary, ensure_ascii=False))
