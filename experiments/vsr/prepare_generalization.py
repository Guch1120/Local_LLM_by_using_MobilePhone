"""(For relations the model never saw, retrain with train_lora.py --exclude and evaluate on those relations of sample1-3.)
Build extra evaluation sets that probe overfitting of a model fine-tuned on VSR's random split. Data goes outside the repository.

usage: python3 prepare_generalization.py [DATA_DIR]      (default ~/data/vsr)
  seen/       165 training questions (images the model was trained on) - in-sample accuracy
  sample3/    a third random-split sample, same mix as sample1/2, untouched while choosing methods
  shapes/     synthetic drawings (coloured shapes on white): left/right/above/below - not photographs at all
"""
import collections, json, os, random, sys, urllib.request
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/vsr")

def fetch(rows, folder):
    os.makedirs(f"{folder}/images", exist_ok=True)
    def get(item):
        name, url = item
        path = f"{folder}/images/{name}"
        if os.path.exists(path): return name
        try: urllib.request.urlretrieve(url, path); return name
        except Exception: return None
    from concurrent.futures import ThreadPoolExecutor
    links = {r["image"]: r["image_link"] for r in rows}
    with ThreadPoolExecutor(8) as pool: ok = {n for n in pool.map(get, links.items()) if n}
    usable = [r for r in rows if r["image"] in ok]
    json.dump(usable, open(f"{folder}/usable.json", "w"))
    print(f"{folder}: {len(usable)} questions")

train = json.load(open(f"{DATA}/train/usable.json"))
rnd = random.Random(5)
seen = rnd.sample(train, 165)
os.makedirs(f"{DATA}/seen/images", exist_ok=True)
for r in seen:
    link = f"{DATA}/seen/images/{r['image']}"
    if not os.path.exists(link): os.symlink(f"{DATA}/train/images/{r['image']}", link)
json.dump(seen, open(f"{DATA}/seen/usable.json", "w")); print("seen:", len(seen), "questions")

# a third random-split sample, disjoint from sample1 and sample2
test = [json.loads(l) for l in open(f"{DATA}/test.jsonl")]
used = {(r["image"], r["caption"]) for s in ("sample1", "sample2") for r in json.load(open(f"{DATA}/{s}/usable.json"))}
want = collections.Counter((r["relation"], r["label"]) for r in json.load(open(f"{DATA}/sample1/usable.json")))
pool = collections.defaultdict(list)
for r in test:
    if (r["image"], r["caption"]) not in used: pool[(r["relation"], r["label"])].append(r)
rnd3 = random.Random(21); pick3 = []
for key, n in want.items():
    rnd3.shuffle(pool[key]); pick3 += pool[key][:n]
fetch(pick3, f"{DATA}/sample3")

# synthetic drawings: two shapes on a white canvas, statements about left/right/above/below
os.makedirs(f"{DATA}/shapes/images", exist_ok=True)
colours = {"red": (220, 40, 40), "blue": (40, 70, 220), "green": (40, 160, 70), "yellow": (235, 200, 30)}
kinds = ["circle", "square", "triangle"]
rows = []
srnd = random.Random(3)
for i in range(240):
    (c1, c2), (k1, k2) = srnd.sample(list(colours), 2), (srnd.choice(kinds), srnd.choice(kinds))
    img = Image.new("RGB", (448, 336), "white"); d = ImageDraw.Draw(img)
    pos = []
    while len(pos) < 2:
        p = (srnd.randint(60, 388), srnd.randint(60, 276))
        if all(abs(p[0] - q[0]) > 90 or abs(p[1] - q[1]) > 90 for q in pos): pos.append(p)
    for (x, y), c, k in zip(pos, (c1, c2), (k1, k2)):
        col = colours[c]
        if k == "circle": d.ellipse([x - 32, y - 32, x + 32, y + 32], fill=col)
        elif k == "square": d.rectangle([x - 30, y - 30, x + 30, y + 30], fill=col)
        else: d.polygon([(x, y - 36), (x - 34, y + 28), (x + 34, y + 28)], fill=col)
    rel, truth = srnd.choice([("left", pos[0][0] < pos[1][0]), ("right", pos[0][0] > pos[1][0]),
                              ("above", pos[0][1] < pos[1][1]), ("below", pos[0][1] > pos[1][1])])
    claim = srnd.random() < 0.5
    phrase = {"left": "to the left of", "right": "to the right of", "above": "above", "below": "below"}[rel]
    asked_true = truth if claim else not truth
    name = f"shape{i:03d}.png"; img.save(f"{DATA}/shapes/images/{name}")
    rows.append({"image": name, "caption": f"The {c1} {k1} is {phrase} the {c2} {k2}.", "label": int(asked_true), "relation": f"shape-{rel}"})
json.dump(rows, open(f"{DATA}/shapes/usable.json", "w")); print("shapes:", len(rows), "true:", sum(r["label"] for r in rows))
