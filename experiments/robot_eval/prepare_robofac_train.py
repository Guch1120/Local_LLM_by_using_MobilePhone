"""Training examples from the RoboFAC simulation videos (MINT-SJTU, MIT license): success detection and error-type questions.

usage: python3 prepare_robofac_train.py [DATA_DIR]      (default ~/data/robot; needs robofac_training_qa.json, robofac_subset_files.json
                                                         and the videos under robofac_sim/)
Writes robofac_train/usable.json: {id, kind (yesno|mcq), question, frames (12 evenly spaced), answer, type, task_text}. The question
text is the one the real-video evaluation uses ("These are N frames ..." is added when the examples are turned into prompts).
"""
import ast, collections, json, os, re, sys
import av

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/robot")
OUT = f"{DATA}/robofac_train"; os.makedirs(f"{OUT}/images", exist_ok=True)
FRAMES = 12
subset = set(json.load(open(f"{DATA}/robofac_subset_files.json"))["files"])
by_uuid = {os.path.basename(p): p for p in subset}
qa = json.load(open(f"{DATA}/robofac_training_qa.json"))

def mcq(question, answer):
    match = re.search(r"\(Your answer should choose one of the following options:\s*(\[.*?\])\)", question, re.S)
    if not match: return None
    options = ast.literal_eval(match.group(1)); answer = answer.strip()
    if answer not in options: return None
    body = question.replace("<video>", "").replace(match.group(0), "").strip()
    lettered = " ".join(f"{chr(65 + i)}. {o}" for i, o in enumerate(options))
    return f"{body} Choices: {lettered}. Please answer directly with only the letter of the correct option and nothing else.", chr(65 + options.index(answer))

per_video = collections.defaultdict(dict)
for x in qa:
    name = os.path.basename(x["video"])
    q, a = x["conversations"][0]["value"], x["conversations"][1]["value"]
    low = q.lower()
    if name not in by_uuid: continue
    if "was it successful" in low:
        per_video[name]["detection"] = ("yes" if a.strip().lower().startswith("yes") else "no", q.replace("<video>", "").strip())
    elif "error type" in low:
        converted = mcq(q, a)
        if converted: per_video[name]["identification"] = converted
    elif "what task" in low or "describe the task" in low or "what is the robot doing" in low or "engaged in" in low:
        per_video[name].setdefault("task_text", a.strip())

items = []
for name, entry in per_video.items():
    if "detection" not in entry and "identification" not in entry: continue
    path = f"{DATA}/robofac_sim/{by_uuid[name]}"
    try:
        with av.open(path) as container:
            decoded = [f.to_image() for f in container.decode(video=0)]
    except Exception as e:
        print("skip", name, repr(e)[:80]); continue
    if len(decoded) < FRAMES: continue
    names = []
    for k in range(FRAMES):
        names.append(f"{name[:-4]}_{k}.jpg"); decoded[round(k * (len(decoded) - 1) / (FRAMES - 1))].save(f"{OUT}/images/{names[-1]}", quality=90)
    task = by_uuid[name].split("/")[1] if "success_data" not in by_uuid[name] else by_uuid[name].split("/")[2]
    base = {"frames": names, "task_text": entry.get("task_text"), "task": task}
    if "detection" in entry:
        items.append({**base, "id": f"{name[:-4]}-detection", "kind": "yesno", "type": "detection", "answer": entry["detection"][0],
                      "question": entry["detection"][1]})
    if "identification" in entry:
        items.append({**base, "id": f"{name[:-4]}-identification", "kind": "mcq", "type": "identification",
                      "question": entry["identification"][0], "answer": entry["identification"][1]})
json.dump(items, open(f"{OUT}/usable.json", "w"))
c = collections.Counter((i["type"], i["answer"] if i["kind"] == "yesno" else "-") for i in items)
print(len(items), "examples:", dict(c), "| with task text:", sum(bool(i["task_text"]) for i in items))
