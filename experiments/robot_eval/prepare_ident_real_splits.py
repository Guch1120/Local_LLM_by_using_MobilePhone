"""Splits of the real RoboFAC error-type questions, by episode, for training on real videos.

usage: python3 prepare_ident_real_splits.py [DATA_DIR]      (default ~/data/robot; needs robofac_real/ from prepare_robofac.py)
Each failed episode was filmed by two cameras (above, rightfront); both views of an episode always go to the same side.
Writes
  mix_R60.json / mix_R25.json    training lists (60% / 15% of the episodes, class-balanced, options in random order) for train_generic.py
  robofac_ident_r40/             test folder: the other 40% of the episodes (both cameras)
  mix_L_<task>.json              training lists of leave-one-task-out runs: all other tasks' episodes
  robofac_ident_loto_<task>/     test folders: every video of the held-out task
"""
import collections, glob, json, os, random, re, sys

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/robot")
PER_CLASS = 192
VIDEO_TASKS = ["InsertCylinder", "StackCube", "PullCubeByTool"]
rnd = random.Random(0)
anns = {}
for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))
episode_of = {key: (entry["video"].split("/")[0], entry["video"].split("/")[-1]) for key, entry in anns.items()}
items = [i for i in json.load(open(f"{DATA}/robofac_real/usable.json")) if i["type"].startswith("identification/")]

def parse(question):
    body, rest = question.split(" Choices: ", 1)
    rest = rest.split(" Please answer")[0]
    return body, [o.strip().rstrip(".").strip() for o in re.split(r"\s*[A-H]\.\s+", rest) if o.strip()]

for i in items:
    i["key"] = i["id"].rsplit("-", 1)[0]; i["episode"] = episode_of[i["key"]]
    body, options = parse(i["question"]); i["class"] = options[ord(i["answer"]) - 65]; i["body"] = body; i["options"] = options

def shuffled(item):
    options = list(item["options"]); rnd.shuffle(options)
    lettered = " ".join(f"{chr(65 + k)}. {o}." for k, o in enumerate(options))
    return (f"{item['body']} Choices: {lettered}. Please answer directly with only the letter of the correct option and nothing else.",
            chr(65 + options.index(item["class"])))

def examples(videos, per_class):
    by_class = collections.defaultdict(list)
    for v in videos: by_class[v["class"]].append(v)
    out = []
    for cls, vs in by_class.items():
        for v in rnd.choices(vs, k=per_class):
            question, answer = shuffled(v)
            out.append({"images": [f"/robot/robofac_real/images/{n}" for n in v["images"]], "system": None, "prompt": question, "answer": answer,
                        "source": "robofac_real", "type": "identification"})
    rnd.shuffle(out)
    return out

def test_folder(name, videos):
    folder = f"{DATA}/{name}"; os.makedirs(folder, exist_ok=True)
    if not os.path.exists(f"{folder}/images"): os.symlink("../robofac_real/images", f"{folder}/images")
    json.dump([{k: v[k] for k in ("id", "kind", "type", "answer", "question", "images", "task")} for v in videos], open(f"{folder}/usable.json", "w"))
    print(f"{name}: {len(videos)} videos, classes {dict(collections.Counter(v['class'] for v in videos))}")

# episode-level 60/40 split, stratified by task and class
episodes = collections.defaultdict(list)
for i in items: episodes[(i["episode"], i["task"], i["class"])].append(i)
by_group = collections.defaultdict(list)
for (episode, task, cls), vs in episodes.items(): by_group[(task, cls)].append(episode)
train_eps, test_eps = set(), set()
for group, eps in by_group.items():
    eps = sorted(set(eps)); rnd.shuffle(eps); cut = round(len(eps) * 0.6)
    train_eps.update(eps[:cut]); test_eps.update(eps[cut:])
train = [i for i in items if i["episode"] in train_eps]; test = [i for i in items if i["episode"] in test_eps]
assert not ({i["episode"] for i in train} & {i["episode"] for i in test})
json.dump(examples(train, PER_CLASS), open(f"{DATA}/mix_R60.json", "w"))
small_eps = set(rnd.sample(sorted({i["episode"] for i in train}), round(len({i["episode"] for i in train}) * 0.25)))
json.dump(examples([i for i in train if i["episode"] in small_eps], PER_CLASS // 4), open(f"{DATA}/mix_R25.json", "w"))
print(f"train videos {len(train)} ({len(train_eps)} episodes), R25 episodes {len(small_eps)}")
test_folder("robofac_ident_r40", test)
for task in VIDEO_TASKS:
    rest = [i for i in items if i["task"] != task]; held = [i for i in items if i["task"] == task]
    json.dump(examples(rest, PER_CLASS), open(f"{DATA}/mix_L_{task}.json", "w"))
    test_folder(f"robofac_ident_loto_{task}", held)
