"""Free-text answers for a few failed real RoboFAC videos: what went wrong, and how to recover (for people to read next to the frames).

usage: explain_hf.py OUT.json [--adapter NAME] [--per-cell 2]
Picks per-cell failed episodes (camera above) for each task and error class, six frames each. The reference texts are RoboFAC's own
annotations (failure explanation, high-level correction).
"""
import argparse, collections, glob, json, os, re, random, torch
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor

ap = argparse.ArgumentParser()
ap.add_argument("out"); ap.add_argument("--adapter"); ap.add_argument("--per-cell", type=int, default=2)
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it-qat")
a = ap.parse_args()
DATA = "/robot"
items = [i for i in json.load(open(f"{DATA}/robofac_real/usable.json")) if i["type"] == "identification/above"]
task_text = {i["id"]: i["task_text"] for i in json.load(open(f"{DATA}/robofac_real12/usable.json"))}
anns = {}
for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))

def label(item):
    body = item["question"].split("Choices:")[1].split("Please answer")[0]
    options = [o.strip().rstrip(".").strip() for o in re.split(r"\s*[A-H]\.\s+", body) if o.strip()]
    return options[ord(item["answer"]) - 65]

cells = collections.defaultdict(list)
for item in items: cells[(item["task"], label(item))].append(item)
rnd = random.Random(1); chosen = []
for key in sorted(cells):
    rnd.shuffle(cells[key]); chosen += cells[key][:a.per_cell]

processor = AutoProcessor.from_pretrained(a.model)
model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map="cuda")
if a.adapter:
    from peft import PeftModel
    model = PeftModel.from_pretrained(model, a.adapter)
model.eval()

def generate(images, text):
    content = [{"type": "image", "image": im} for im in images] + [{"type": "text", "text": text}]
    prompt = processor.apply_chat_template([{"role": "user", "content": content}], tokenize=False, add_generation_prompt=True)
    inputs = processor(text=prompt, images=images, return_tensors="pt").to("cuda")
    with torch.no_grad():
        out = model.generate(**inputs, max_new_tokens=90, do_sample=False)
    return processor.tokenizer.decode(out[0, inputs["input_ids"].shape[1]:], skip_special_tokens=True).strip()

results = []
for item in chosen:
    key = item["id"].rsplit("-", 1)[0]
    images = [Image.open(f"{DATA}/robofac_real/images/{n}").convert("RGB") for n in item["images"]]
    lead = "These are six frames in time order from a video of a robotic arm. "
    task = f"The robot's task is: {task_text[key]} The task failed. "
    reference = {c: [m["value"] for m in t][1] for c, t in anns[key]["annos"].items() if c in ("Failure explanation", "High-level correction")}
    results.append({"id": item["id"], "task": item["task"], "class": label(item), "frames": item["images"], "task_text": task_text[key],
                    "model_explanation": generate(images, lead + task + "Describe in one or two sentences what went wrong."),
                    "model_recovery": generate(images, lead + task + "In one or two sentences, what should the robot do to recover?"),
                    "reference_explanation": reference.get("Failure explanation"), "reference_correction": reference.get("High-level correction")})
    print(len(results), "/", len(chosen), flush=True)
json.dump(results, open(a.out, "w"), ensure_ascii=False)
