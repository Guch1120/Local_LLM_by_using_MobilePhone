"""Download VSR (Visual Spatial Reasoning, Liu et al., TACL 2023, CC BY 4.0; images from COCO, CC BY 2.0)
and build the evaluation samples and the leak-free training set. Data goes outside the repository.

usage: python3 prepare.py [DATA_DIR]      (default ~/data/vsr)
  sample1/  168 test questions picked with seed 11 (14 relations x true/false x 6), unanimous validators
  sample2/  a second, non-overlapping sample with the same relation/label mix (seed 7)
  train/    random-split train questions whose image is not in the test split (no image shared with any test question)
"""
import json, os, random, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/vsr")
BASE = "https://raw.githubusercontent.com/cambridgeltl/visual-spatial-reasoning/master/data/splits/random/"
FOCUS = ["on", "under", "above", "below", "behind", "in front of", "at the left side of", "at the right side of",
         "next to", "beside", "inside", "touching", "near", "contains"]

def unanimous(r):
    t, f = len(json.loads(r["vote_true_validator_id"])), len(json.loads(r["vote_false_validator_id"]))
    return (r["label"] == 1 and f == 0 and t >= 2) or (r["label"] == 0 and t == 0 and f >= 2)

def fetch_images(rows, folder):
    os.makedirs(f"{folder}/images", exist_ok=True)
    links = {r["image"]: r["image_link"] for r in rows}
    def get(item):
        name, url = item; path = f"{folder}/images/{name}"
        if os.path.exists(path): return name
        try: urllib.request.urlretrieve(url, path); return name
        except Exception: return None
    with ThreadPoolExecutor(8) as pool: ok = {n for n in pool.map(get, links.items()) if n}
    usable = [r for r in rows if r["image"] in ok]
    json.dump(usable, open(f"{folder}/usable.json", "w"))
    print(f"{folder}: {len(usable)} of {len(rows)} questions have their image")

os.makedirs(DATA, exist_ok=True)
for split in ("train", "test"):
    if not os.path.exists(f"{DATA}/{split}.jsonl"): urllib.request.urlretrieve(BASE + f"{split}.jsonl", f"{DATA}/{split}.jsonl")
train = [json.loads(l) for l in open(f"{DATA}/train.jsonl")]
test = [json.loads(l) for l in open(f"{DATA}/test.jsonl")]

good = [r for r in test if unanimous(r) and r["image_link"].startswith("http://images.cocodataset.org/")]
rnd = random.Random(11); picked = []
for rel in FOCUS:
    for label in (1, 0):
        pool = [r for r in good if r["relation"] == rel and r["label"] == label]
        rnd.shuffle(pool); picked += pool[:6]
fetch_images(picked, f"{DATA}/sample1")
used = {(r["image"], r["caption"]) for r in json.load(open(f"{DATA}/sample1/usable.json"))}

import collections
want = collections.Counter((r["relation"], r["label"]) for r in json.load(open(f"{DATA}/sample1/usable.json")))
random.seed(7)
pool = collections.defaultdict(list)
for r in test:
    if (r["image"], r["caption"]) not in used: pool[(r["relation"], r["label"])].append(r)
picked2 = []
for key, n in want.items():
    random.shuffle(pool[key]); picked2 += pool[key][:n]
fetch_images(picked2, f"{DATA}/sample2")

test_images = {r["image"] for r in test}
clean = [r for r in train if r["image"] not in test_images]
fetch_images(clean, f"{DATA}/train")
