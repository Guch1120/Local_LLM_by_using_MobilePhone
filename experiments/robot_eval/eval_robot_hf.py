"""Score Gemma 4 E2B (optionally with a LoRA adapter) on the robot benchmarks made by prepare.py.

  yes/no questions: log p(Yes) - log p(No) at the first answer token (--format native), or the VSR-style verdict
                    log p(true) - log p(false) for the statement "the answer to this question is yes" (--format json,
                    the format the adapter was trained on)
  multiple choice : the option letter with the highest probability at the first answer token
Reports accuracy, and ROC-AUC for yes/no questions.
"""
import argparse, json, math, os, time, torch
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it-qat"); ap.add_argument("--adapter")
ap.add_argument("--data", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--format", default="native", choices=["native", "json"]); ap.add_argument("--limit", type=int, default=10**9)
ap.add_argument("--max-soft-tokens", type=int, default=0, help="image token budget per frame (the processor default is 280; video input uses 70)")
ap.add_argument("--types", default="", help="comma-separated question types to keep (for example identification/above)")
a = ap.parse_args()

SYSTEM = ("Look at the image and decide whether the statement about it is true. "
          "Answer with JSON only: {\"assessment\": \"true\" | \"false\"}.")
PREFIX = '{"assessment": "'

processor = AutoProcessor.from_pretrained(a.model)
if a.max_soft_tokens: processor.image_processor.max_soft_tokens = a.max_soft_tokens
model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map="cuda")
if a.adapter:
    from peft import PeftModel
    model = PeftModel.from_pretrained(model, a.adapter)
model.eval()
tok = processor.tokenizer
first = lambda w: tok.encode(w, add_special_tokens=False)[0]
ids = {w: sorted({first(v) for v in (w, " " + w, w.lower(), w.capitalize())}) for w in ("yes", "no", "true", "false")}
letter_ids = {c: sorted({first(c), first(" " + c)}) for c in "ABCDEFGH"}

def lse(logprobs, tokens):
    return torch.logsumexp(logprobs[tokens], 0).item()

def run(item, folder):
    images = [Image.open(f"{folder}/images/{n}").convert("RGB") for n in item["images"]]
    content = [{"type": "image", "image": im} for im in images]
    json_mode = item["kind"] == "yesno" and a.format == "json"
    if item["kind"] == "yesno":
        text = (f"Statement: the answer to this question is yes. Question: {item['question']}" if json_mode
                else item["question"] + " Answer yes or no.")
    else:
        text = item["question"]
    content.append({"type": "text", "text": text})
    messages = ([{"role": "system", "content": [{"type": "text", "text": SYSTEM}]}] if json_mode else []) + [{"role": "user", "content": content}]
    prompt = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True) + (PREFIX if json_mode else "")
    inputs = processor(text=prompt, images=images, return_tensors="pt").to("cuda")
    with torch.no_grad():
        lp = torch.log_softmax(model(**inputs).logits[0, -1].float(), -1)
    if item["kind"] == "yesno":
        pos, neg = ("true", "false") if json_mode else ("yes", "no")
        return {"score": lse(lp, ids[pos]) - lse(lp, ids[neg])}
    letters = [c for c in "ABCDEFGH" if f"{c}." in item["question"] or f"({c})" in item["question"]] or list("ABCD")
    scores = {c: lse(lp, letter_ids[c]) for c in letters}
    return {"choice": max(scores, key=scores.get)}

folder = a.data
items = json.load(open(f"{folder}/usable.json"))
if a.types: items = [i for i in items if i.get("type") in a.types.split(",")]
items = items[:a.limit]
results, start = [], time.time()
for item in items:
    try: r = run(item, folder)
    except Exception as e: print("skip", item["id"], repr(e)[:120]); continue
    r.update({"id": item["id"], "kind": item["kind"], "type": item.get("type"), "answer": item["answer"]}); results.append(r)

def auc(rows):
    pos = [r["score"] for r in rows if r["answer"] == "yes"]; neg = [r["score"] for r in rows if r["answer"] == "no"]
    return sum((p > n) + 0.5 * (p == n) for p in pos for n in neg) / (len(pos) * len(neg)) if pos and neg else float("nan")

def correct(r):
    return (r["score"] > 0) == (r["answer"] == "yes") if r["kind"] == "yesno" else r["choice"] == r["answer"]

def breakdown(rows):
    """Accuracy (and ROC-AUC for yes/no questions) overall and for each question type."""
    def one(part):
        out = {"n": len(part), "accuracy": round(sum(map(correct, part)) / len(part), 3)}
        if part[0]["kind"] == "yesno":
            out["auc"] = round(auc(part), 3); out["says_yes"] = round(sum(r["score"] > 0 for r in part) / len(part), 3)
        return out
    result = one(rows)
    types = sorted({r["type"] for r in rows if r["type"]})
    if types: result["by_type"] = {t: one([r for r in rows if r["type"] == t]) for t in types}
    return result

summary = {"model": a.adapter or a.model, "format": a.format, "seconds": round(time.time() - start)}
for kind in ("yesno", "mcq"):
    part = [r for r in results if r["kind"] == kind]
    if part: summary[kind] = breakdown(part)
json.dump({"summary": summary, "results": results}, open(a.out, "w"))
print(json.dumps(summary, ensure_ascii=False))
