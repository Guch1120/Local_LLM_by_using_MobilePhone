"""Turn the robot-related benchmarks into the folder layout the evaluation scripts read. Data goes outside the repository.

usage: python3 prepare.py [DATA_DIR]      (default ~/data/robot; parquet files and RoboFAC videos are fetched by the commands in README)
  robospatial_configuration/, robospatial_compatibility/   yes/no questions about a real indoor photo (RoboSpatial-Home, Apache-2.0)
  erqa/                                                    400 multiple-choice questions on embodied reasoning (ERQA)
Each folder holds images/ and usable.json: a list of {id, question, images:[file], answer, kind}.
"""
import io, json, os, sys
import pandas as pd
from PIL import Image

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/robot")

def save(image_bytes, path, max_side=1280):
    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    if max(img.size) > max_side:
        img.thumbnail((max_side, max_side))
    img.save(path, quality=92)

def write(name, items):
    json.dump(items, open(f"{DATA}/{name}/usable.json", "w"))
    print(f"{name}: {len(items)} questions")

for split in ("configuration", "compatibility"):
    folder = f"robospatial_{split}"; os.makedirs(f"{DATA}/{folder}/images", exist_ok=True)
    df = pd.read_parquet(f"{DATA}/robospatial_{split}.parquet")
    items = []
    for i, row in df.iterrows():
        name = f"{split}_{i:03d}.jpg"; save(row["img"]["bytes"], f"{DATA}/{folder}/images/{name}")
        items.append({"id": f"{split}-{i}", "question": row["question"].replace("Answer yes or no.", "").strip(),
                      "images": [name], "answer": "yes" if str(row["answer"]).strip().lower() == "yes" else "no", "kind": "yesno"})
    write(folder, items)

os.makedirs(f"{DATA}/erqa/images", exist_ok=True)
df = pd.read_parquet(f"{DATA}/erqa.parquet"); items = []
for i, row in df.iterrows():
    names = []
    for j, image in enumerate(row["images"]):
        names.append(f"erqa_{i:03d}_{j}.jpg"); save(image["bytes"], f"{DATA}/erqa/images/{names[-1]}")
    items.append({"id": row["question_id"], "question": row["question"], "images": names, "answer": str(row["answer"]).strip().upper(),
                  "kind": "mcq", "type": row["question_type"]})
write("erqa", items)
