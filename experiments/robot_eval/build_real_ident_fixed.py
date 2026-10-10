"""Real RoboFAC error types, trained as a plain classification: the answer is the class name itself (no letters to map to options).

usage: build_real_ident_fixed.py TAG --split leaky|loto [--task NAME] [--per-class 192]
Writes ~/data/robot/mix_TAG.json (training list for train_generic.py) and the test folder ~/data/robot/robofac_cls_TAG/ (kind "classify").
  leaky : 60% of the episodes for training, 40% for testing (neighbours of a recording block are on both sides: only a learnability check)
  loto  : every video of the task NAME is the test set, the other five tasks are the training set (no shortcut through the recording batch)
Frames: six evenly spaced, both cameras as separate examples. The prompt states the task and lists the three classes (in a random order for training).
"""
import argparse, collections, glob, json, os, random, re

ap = argparse.ArgumentParser()
ap.add_argument("tag"); ap.add_argument("--split", required=True, choices=["leaky", "loto"]); ap.add_argument("--task", default="")
ap.add_argument("--per-class", type=int, default=192); ap.add_argument("--seed", type=int, default=0)
a = ap.parse_args()
DATA = os.path.expanduser("~/data/robot"); rnd = random.Random(a.seed)
CLASSES = ["Orientation deviation", "Grasping error", "Position deviation"]
anns = {}
for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))
task_text = {i["id"]: i["task_text"] for i in json.load(open(f"{DATA}/robofac_real12/usable.json"))}
items = []
for i in json.load(open(f"{DATA}/robofac_real/usable.json")):
    if not i["type"].startswith("identification/"): continue
    key = i["id"].rsplit("-", 1)[0]; body = i["question"].split("Choices:")[1].split("Please answer")[0]
    options = [o.strip().rstrip(".").strip() for o in re.split(r"\s*[A-H]\.\s+", body) if o.strip()]
    video = anns[key]["video"]
    items.append({"key": key, "task": i["task"], "class": options[ord(i["answer"]) - 65], "images": i["images"], "text": task_text[key],
                  "episode": (video.split("/")[0], video.split("/")[-1])})

def prompt(item, shuffle):
    names = list(CLASSES); (rnd.shuffle(names) if shuffle else None)
    return (f"These are six frames in time order from a video of a robotic arm. The robot's task is: {item['text']} The task failed. "
            f"What was the error type? Answer with one of: {', '.join(names)}.")

if a.split == "leaky":
    groups = collections.defaultdict(set)
    for i in items: groups[(i["task"], i["class"])].add(i["episode"])
    train_eps = set()
    for eps in groups.values():
        eps = sorted(eps); rnd.shuffle(eps); train_eps.update(eps[:round(len(eps) * 0.6)])
    train = [i for i in items if i["episode"] in train_eps]; test = [i for i in items if i["episode"] not in train_eps]
else:
    train = [i for i in items if i["task"] != a.task]; test = [i for i in items if i["task"] == a.task]
by_class = collections.defaultdict(list)
for i in train: by_class[i["class"]].append(i)
mix = []
for cls, vs in by_class.items():
    for v in rnd.choices(vs, k=a.per_class):
        mix.append({"images": [f"/robot/robofac_real/images/{n}" for n in v["images"]], "system": None, "prompt": prompt(v, True), "answer": cls,
                    "source": "robofac_real", "type": "ident_fixed"})
rnd.shuffle(mix); json.dump(mix, open(f"{DATA}/mix_{a.tag}.json", "w"))
folder = f"{DATA}/robofac_cls_{a.tag}"; os.makedirs(folder, exist_ok=True)
if not os.path.exists(f"{folder}/images"): os.symlink("../robofac_real/images", f"{folder}/images")
json.dump([{"id": v["key"], "kind": "classify", "type": "ident_fixed", "answer": v["class"], "labels": CLASSES, "question": prompt(v, False),
            "images": v["images"], "task": v["task"]} for v in test], open(f"{folder}/usable.json", "w"))
print(f"{a.tag}: train videos {len(train)} -> {len(mix)} examples; test videos {len(test)}, classes",
      dict(collections.Counter(v["class"] for v in test)), "| tasks in test:", sorted({v["task"] for v in test}))
