"""Build evaluation questions from the real-robot videos of RoboFAC (MINT-SJTU, MIT license): SO-100 arm, 6 tasks, two cameras.

usage: python3 prepare_robofac.py [DATA_DIR]      (default ~/data/robot; needs robofac/ annotations and robofac_data/realworld_data/ videos)
Six frames evenly spaced over each video become the images. Three question types per video:
  detection       was the task successful? (yes/no; 244 successes, 960 failures)
  identification  which error type? (multiple choice, failures only)
  locating        during which subtask did the error happen? (multiple choice, failures only)
"""
import ast, glob, json, os, re, sys
import av

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/robot")
FRAMES = 6
OUT = f"{DATA}/robofac_real"; os.makedirs(f"{OUT}/images", exist_ok=True)
anns = {}
for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))

def frames(video, key):
    """Six evenly spaced frames, decoded with PyAV (the videos are AV1, which OpenCV cannot read here)."""
    with av.open(f"{DATA}/robofac_data/realworld_data/{video}") as container:
        decoded = [f.to_image() for f in container.decode(video=0)]
    if len(decoded) < FRAMES: return None
    names = []
    for k in range(FRAMES):
        names.append(f"{key}_{k}.jpg"); decoded[round(k * (len(decoded) - 1) / (FRAMES - 1))].save(f"{OUT}/images/{names[-1]}", quality=90)
    return names

def mcq(question, answer):
    """Turn "(... choose one of the following options: ['a', 'b'])" into lettered options; None if the answer is not among them."""
    match = re.search(r"\(Your answer should choose one of the following options:\s*(\[.*?\])\)", question, re.S)
    if not match: return None
    options = ast.literal_eval(match.group(1)); answer = answer.strip()
    if answer not in options: return None
    body = question.replace("<image>", "").replace(match.group(0), "").strip()
    lettered = " ".join(f"{chr(65 + i)}. {o}" for i, o in enumerate(options))
    return f"{body} Choices: {lettered}. Please answer directly with only the letter of the correct option and nothing else.", chr(65 + options.index(answer))

ITEMS = []
for key, entry in anns.items():
    names = frames(entry["video"], key)
    if not names: continue
    camera = "above" if "images.above" in entry["video"] else "rightfront"
    lead = "These are six frames in time order from a video of a robotic arm. "
    qa = {c: [m["value"] for m in turns] for c, turns in entry["annos"].items()}
    detection = qa["Failure detection"]
    ITEMS.append({"id": f"{key}-detection", "question": lead + detection[0].replace("<image>", "").strip(), "images": names,
                  "answer": "yes" if detection[1].strip().lower().startswith("yes") else "no", "kind": "yesno",
                  "type": f"detection/{camera}", "task": entry["task"]})
    for category, name in (("Failure identification", "identification"), ("Failure locating", "locating")):
        if category not in qa: continue
        converted = mcq(qa[category][0], qa[category][1])
        if converted:
            ITEMS.append({"id": f"{key}-{name}", "question": lead + converted[0], "images": names, "answer": converted[1],
                          "kind": "mcq", "type": f"{name}/{camera}", "task": entry["task"]})
json.dump(ITEMS, open(f"{OUT}/usable.json", "w"))
import collections
print(len(ITEMS), "questions;", dict(collections.Counter(i["type"] for i in ITEMS)))
