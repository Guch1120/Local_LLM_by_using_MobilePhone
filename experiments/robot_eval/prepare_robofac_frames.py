"""Frame sets for testing how the input changes success detection on the real RoboFAC videos (needs prepare_robofac.py's data).

usage: python3 prepare_robofac_frames.py [DATA_DIR]      (default ~/data/robot)
Writes robofac_real12/usable.json: one item per video with 12 evenly spaced frames, the task description (the answer to the
"what is the robot doing" question) and the label (yes = the task succeeded). The evaluation script picks frames from the 12.
"""
import glob, json, os, sys
import av

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/robot")
OUT = f"{DATA}/robofac_real12"; os.makedirs(f"{OUT}/images", exist_ok=True)
FRAMES = 12
anns = {}
for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))
items = []
for key, entry in anns.items():
    with av.open(f"{DATA}/robofac_data/realworld_data/{entry['video']}") as container:
        decoded = [f.to_image() for f in container.decode(video=0)]
    if len(decoded) < FRAMES: continue
    names = []
    for k in range(FRAMES):
        names.append(f"{key}_{k}.jpg"); decoded[round(k * (len(decoded) - 1) / (FRAMES - 1))].save(f"{OUT}/images/{names[-1]}", quality=90)
    qa = {c: [m["value"] for m in turns] for c, turns in entry["annos"].items()}
    items.append({"id": key, "camera": "above" if "images.above" in entry["video"] else "rightfront", "task": entry["task"],
                  "task_text": qa["Task identification"][1].strip(), "frames": names,
                  "answer": "yes" if qa["Failure detection"][1].strip().lower().startswith("yes") else "no"})
json.dump(items, open(f"{OUT}/usable.json", "w"))
print(len(items), "videos;", sum(i["answer"] == "yes" for i in items), "successes")
