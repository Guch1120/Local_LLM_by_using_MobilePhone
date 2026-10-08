"""Success detection on the real RoboFAC videos through the phone's API (several frames and the task text in one request).

usage: probe_robofac_phone.py MODEL OUT.json [--variant tasklast3] [--camera above] [--limit N]
Same prompts and frames as eval_robofac_variants.py; the score is log p(Yes) - log p(No) at the first answer token.
"""
import argparse, base64, json, math, os, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("out")
ap.add_argument("--variant", default="tasklast3"); ap.add_argument("--camera", default="above"); ap.add_argument("--limit", type=int, default=10**9)
ap.add_argument("--data", default=os.path.expanduser("~/data/robot/robofac_real12"))
a = ap.parse_args()
KEY = open(os.path.expanduser("~/.config/iphone-local-ai/api-key")).read().strip()
PICK = {"tasklast3": [9, 10, 11], "tasklast1": [11], "tasklast2": [10, 11], "tasklast6": [6, 7, 8, 9, 10, 11], "taskgap4": [5, 7, 9, 11],
        "even6": [0, 2, 4, 7, 9, 11], "last3": [9, 10, 11]}
WORDS = {2: "two", 3: "three", 4: "four", 6: "six"}
idx = PICK[a.variant]
lead = "This is one frame from a video of a robotic arm. " if len(idx) == 1 else f"These are {WORDS[len(idx)]} frames in time order from a video of a robotic arm. "

def ask(item):
    if a.variant.startswith("task"):
        question = f"The robot's task is: {item['task_text']} Was the task completed successfully? Answer yes or no."
    else:
        question = "In the video, the robotic arm executes a task, was it successful? Answer yes or no."
    content = []
    for k in idx:
        data = base64.b64encode(open(f"{a.data}/images/{item['frames'][k]}", "rb").read()).decode()
        content.append({"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + data}})
    content.append({"type": "text", "text": lead + question})
    body = {"model": a.model, "temperature": 0, "max_tokens": 2, "logprobs": True, "top_logprobs": 10,
            "chat_template_kwargs": {"enable_thinking": False}, "messages": [{"role": "user", "content": content}]}
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    top = json.load(urllib.request.urlopen(req, timeout=600))["choices"][0]["logprobs"]["content"][0]["top_logprobs"]
    mass = {"yes": 0.0, "no": 0.0}
    for t in top:
        word = t["token"].strip().lower()
        if word in mass: mass[word] += math.exp(t["logprob"])
    return math.log(max(mass["yes"], 1e-9)) - math.log(max(mass["no"], 1e-9))

def auc(rows):
    pos = [r["score"] for r in rows if r["answer"] == "yes"]; neg = [r["score"] for r in rows if r["answer"] == "no"]
    return sum((p > n) + 0.5 * (p == n) for p in pos for n in neg) / (len(pos) * len(neg)) if pos and neg else float("nan")

items = [i for i in json.load(open(f"{a.data}/usable.json")) if a.camera in ("all", i["camera"])][:a.limit]
rows, failed, start = [], 0, time.time()
for item in items:
    try: rows.append({"id": item["id"], "answer": item["answer"], "task": item["task"], "score": ask(item)})
    except Exception as e: failed += 1
best = max(((sum((r["score"] > t) == (r["answer"] == "yes") for r in rows) / len(rows)), t) for t in sorted({r["score"] for r in rows})) if rows else (0, 0)
summary = {"model": a.model, "variant": a.variant, "n": len(rows), "failed": failed, "auc": round(auc(rows), 3),
           "best_threshold_accuracy": round(best[0], 3), "seconds": round(time.time() - start)}
json.dump({"summary": summary, "results": rows}, open(a.out, "w")); print(json.dumps(summary))
