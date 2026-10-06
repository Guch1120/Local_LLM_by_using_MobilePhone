"""Ask a model on the phone whether each VSR statement is true; record log p(true) - log p(false) at the answer token.

usage: probe.py MODEL OUT.json --data DIR [--variant base|question|twostep|boxes|leftright] [--think] [--no-image] [--limit N]
  --data      a folder made by prepare.py (sample1/, sample2/)
  twostep     first describe where the objects are, then judge using that description (two requests per question)
  --think     enable thinking and allow 3000 output tokens
  --no-image  show the statement alone (a control: accuracy should fall to chance)
The API key is read from ~/.config/iphone-local-ai/api-key; the phone must be forwarded to 127.0.0.1:8080.
"""
import argparse, base64, json, math, os, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("out"); ap.add_argument("--data", required=True)
ap.add_argument("--variant", default="base", choices=["base", "question", "twostep", "boxes", "leftright"])
ap.add_argument("--think", action="store_true"); ap.add_argument("--no-image", action="store_true")
ap.add_argument("--limit", type=int, default=10**9)
a = ap.parse_args()
KEY = open(os.path.expanduser("~/.config/iphone-local-ai/api-key")).read().strip()
SYSTEM = ("Decide whether the statement is true. " if a.no_image else "Look at the image and decide whether the statement about it is true. ") \
    + 'Answer with JSON only: {"assessment": "true" | "false"}.'
FIRST_STEP = {
    "twostep": "Describe where the objects mentioned in this statement are in the picture (left, right, top, bottom, whether they touch or overlap), without judging the statement: ",
    "boxes": "Locate each object mentioned in this statement. For each, give its bounding box as JSON [x_min, y_min, x_max, y_max] in fractions of the image width and height (0 to 1). Do not judge the statement: ",
    "leftright": "For each object mentioned in this statement, say which part of the image it is in horizontally (left, middle, right) and vertically (top, middle, bottom), and whether it overlaps the other object. Do not judge the statement: ",
}

def call(body):
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=600))

def image_part(row):
    data = base64.b64encode(open(f"{a.data}/images/{row['image']}", "rb").read()).decode()
    return {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + data}}

def ask(row):
    text = f"Statement: {row['caption']}"
    if a.variant == "question":
        text = f"Question: is it true that {row['caption'].rstrip('.').lower()}?"
    elif a.variant in FIRST_STEP:
        first = call({"model": a.model, "temperature": 0, "max_tokens": 120, "chat_template_kwargs": {"enable_thinking": False},
                      "messages": [{"role": "user", "content": [{"type": "text", "text": FIRST_STEP[a.variant] + row["caption"]}, image_part(row)]}]})
        text += "\nWhat you observed: " + first["choices"][0]["message"]["content"].strip()
    content = [{"type": "text", "text": text}] + ([] if a.no_image else [image_part(row)])
    return call({"model": a.model, "temperature": 0, "max_tokens": 3000 if a.think else 24, "logprobs": True, "top_logprobs": 10,
                 "chat_template_kwargs": {"enable_thinking": a.think},
                 "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": content}]})

def p_true_false(choice):
    """Probability mass on 'true' and 'false' where the model wrote the verdict (the last such token, after any reasoning).
    Tokens that differ only by a leading space or quote are added together."""
    for t in reversed(choice["logprobs"]["content"]):
        if t["token"].strip().strip('"').lower() not in ("true", "false"): continue
        mass = {"true": 0.0, "false": 0.0}
        for c in t["top_logprobs"]:
            name = c["token"].strip().strip('"').lower()
            if name in mass: mass[name] += math.exp(c["logprob"])
        return mass["true"], mass["false"]
    return None

rows = json.load(open(f"{a.data}/usable.json"))[:a.limit]
results, stats, missing, start = [], [], 0, time.time()
for r in rows:
    try:
        t0 = time.time(); d = ask(r); pf = p_true_false(d["choices"][0])
        stats.append((time.time() - t0, d["usage"]["completion_tokens"], d["choices"][0]["finish_reason"]))
    except Exception:
        pf = None
    if pf is None: missing += 1; continue
    pt, pfa = pf
    results.append({"relation": r["relation"], "label": r["label"], "p_true": pt, "p_false": pfa,
                    "score": math.log(max(pt, 1e-9)) - math.log(max(pfa, 1e-9))})
json.dump({"model": a.model, "variant": a.variant, "no_image": a.no_image, "think": a.think,
           "seconds": [s[0] for s in stats], "tokens": [s[1] for s in stats], "results": results}, open(a.out, "w"))
n = len(results); acc = sum((x["score"] > 0) == bool(x["label"]) for x in results) / max(1, n)
print(f"{a.model} {a.variant}{' think' if a.think else ''}{' NO IMAGE' if a.no_image else ''}: {n} usable of {len(rows)} (missing {missing}), "
      f"accuracy at the model's own threshold {100*acc:.1f}%, {time.time()-start:.0f} s")
if stats:
    print(f"mean {sum(s[0] for s in stats)/len(stats):.1f} s and {sum(s[1] for s in stats)/len(stats):.0f} generated tokens per question; "
          f"cut off by the limit: {sum(s[2] == 'length' for s in stats)}")
