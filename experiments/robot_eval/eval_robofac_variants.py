"""Success detection on the real RoboFAC videos with different inputs (frame choice, task description, windows over time).

Variants (all ask yes/no; the score is log p(yes) - log p(no), higher = more likely a success):
  even6      six evenly spaced frames, as in the first evaluation
  last3      the last three frames only (the end state)
  firstlast  the first and the last frame
  even12     twelve evenly spaced frames
  task6      even6, and the prompt states the robot's task
  tasklast3  last3, and the prompt states the robot's task
  window     four consecutive windows of three frames, each asked "did an error occur?"; the video's score is the
             lowest value of -(error score) over the windows, so one bad window makes the video a failure
"""
import argparse, json, os, time, torch
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it-qat"); ap.add_argument("--adapter")
ap.add_argument("--data", default="/robot/robofac_real12"); ap.add_argument("--out", required=True)
ap.add_argument("--variants", default="even6,last3,firstlast,even12,task6,tasklast3,window")
ap.add_argument("--camera", default="above"); ap.add_argument("--limit", type=int, default=10**9)
a = ap.parse_args()

processor = AutoProcessor.from_pretrained(a.model)
model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map="cuda")
if a.adapter:
    from peft import PeftModel
    model = PeftModel.from_pretrained(model, a.adapter)
model.eval()
tok = processor.tokenizer
first = lambda w: tok.encode(w, add_special_tokens=False)[0]
ids = {w: sorted({first(v) for v in (w, " " + w, w.capitalize())}) for w in ("yes", "no")}

def ask(images, text):
    content = [{"type": "image", "image": im} for im in images] + [{"type": "text", "text": text}]
    prompt = processor.apply_chat_template([{"role": "user", "content": content}], tokenize=False, add_generation_prompt=True)
    inputs = processor(text=prompt, images=images, return_tensors="pt").to("cuda")
    with torch.no_grad():
        lp = torch.log_softmax(model(**inputs).logits[0, -1].float(), -1)
    return torch.logsumexp(lp[ids["yes"]], 0).item() - torch.logsumexp(lp[ids["no"]], 0).item()

PICK = {"even6": [0, 2, 4, 7, 9, 11], "last3": [9, 10, 11], "firstlast": [0, 11], "even12": list(range(12)),
        "task6": [0, 2, 4, 7, 9, 11], "tasklast3": [9, 10, 11]}
WORDS = {2: "two", 3: "three", 6: "six", 12: "twelve"}

def score(variant, item, load):
    if variant == "window":
        errors = [ask(load(range(w, w + 3)), f"These are three consecutive frames in time order from a video of a robotic arm. "
                      f"The robot's task is: {item['task_text']} Did an error occur in these frames (for example the object slipped, "
                      f"was dropped, missed its target or was knocked over)? Answer yes or no.") for w in (0, 3, 6, 9)]
        return -max(errors)
    idx = PICK[variant]
    lead = f"These are {WORDS[len(idx)]} frames in time order from a video of a robotic arm. "
    if variant.startswith("task"):
        question = f"The robot's task is: {item['task_text']} Was the task completed successfully? Answer yes or no."
    else:
        question = "In the video, the robotic arm executes a task, was it successful? Answer yes or no."
    return ask(load(idx), lead + question)

def auc(rows):
    pos = [r["score"] for r in rows if r["answer"] == "yes"]; neg = [r["score"] for r in rows if r["answer"] == "no"]
    return sum((p > n) + 0.5 * (p == n) for p in pos for n in neg) / (len(pos) * len(neg)) if pos and neg else float("nan")

items = [i for i in json.load(open(f"{a.data}/usable.json")) if a.camera in ("all", i["camera"])][:a.limit]
summary, results = {"model": a.adapter or a.model, "camera": a.camera, "n": len(items)}, {}
for variant in a.variants.split(","):
    start, rows = time.time(), []
    for item in items:
        load = lambda ks, item=item: [Image.open(f"{a.data}/images/{item['frames'][k]}").convert("RGB") for k in ks]
        rows.append({"id": item["id"], "answer": item["answer"], "task": item["task"], "score": score(variant, item, load)})
    results[variant] = rows
    best = max(((sum((r["score"] > t) == (r["answer"] == "yes") for r in rows) / len(rows)), t) for t in sorted({r["score"] for r in rows}))
    summary[variant] = {"auc": round(auc(rows), 3), "best_threshold_accuracy": round(best[0], 3), "seconds": round(time.time() - start)}
    print(variant, summary[variant], flush=True)
    json.dump({"summary": summary, "results": results}, open(a.out, "w"))
