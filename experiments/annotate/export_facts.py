"""Training examples that teach the model to report what can be seen (the facts of facts.json), and a check of the facts against the dataset's own labels.

usage: export_facts.py [--out ~/data/robot/mix_facts.json] [--annotations annotations.jsonl ...]
 - For every annotated episode, the six evenly spaced frames of each camera (the two cameras give two examples), the task text, and the JSON of the facts as the answer
   (the fields answered with 'unclear' stay in: the model should learn to say it).
 - The summary compares a simple rule that turns the facts into a RoboFAC failure type with the dataset's label (grasping: reached but not held, not lifted
   or dropped; orientation: tilted or rotated; position: near or far from the goal, or a miss direction). It checks that the facts carry the information
   and that the annotators agree with the labels; it is not used for training.
Frames are written to ~/data/robot/fact_frames/. Only the RoboFAC videos are handled here (for your own videos, add the camera names to CAMERAS).
"""
import argparse, collections, glob, json, os, re
import av

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="~/data/robot/mix_facts.json"); ap.add_argument("--annotations", nargs="*", default=None)
ap.add_argument("--frames", type=int, default=6)
a = ap.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__)); DATA = os.path.expanduser("~/data/robot")
CAMERAS = ["above", "rightfront"]
facts_spec = json.load(open(f"{HERE}/facts.json"))["facts"]
records = {}
for path in (a.annotations or [f"{HERE}/annotations.jsonl"]):
    for line in open(path):
        r = json.loads(line); records[r["id"]] = r
anns = {}
for p in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(p)))
dataset_class = {}
for e in anns.values():
    if "Failure identification" in e["annos"] and "images.above" in e["video"]:
        dataset_class[f"{e['video'].split('/')[0]}/{e['video'].split('/')[-1][:-4]}"] = [m["value"] for m in e["annos"]["Failure identification"]][1].strip()

def rule(f):
    if f.get("reached_object") == "yes" and (f.get("closed_on_object") in ("no", "never_closed") or f.get("object_lifted") == "no" or f.get("dropped") == "yes"): return "Grasping error"
    if f.get("final_orientation") == "tilted_or_rotated": return "Orientation deviation"
    if f.get("final_vs_goal") in ("near_goal", "far_from_goal") or f.get("miss_direction") in ("short", "overshoot", "left", "right"): return "Position deviation"
    return "unknown"

failures = [r for r in records.values() if r.get("visible") == "failure" and r.get("facts")]
table = collections.Counter((dataset_class.get(r["id"], "?"), rule(r["facts"])) for r in failures)
print(f"{len(records)} annotated, {len(failures)} marked as failures with facts. Rule-derived type (columns) vs the dataset's label (rows):")
labels = sorted({k[0] for k in table}); preds = sorted({k[1] for k in table})
print(" " * 24 + "".join(f"{p[:14]:>16}" for p in preds))
for l in labels: print(f"{l:<24}" + "".join(f"{table[(l, p)]:>16}" for p in preds))
agree = sum(v for (l, p), v in table.items() if l == p); print("agreement:", f"{100*agree/max(1,len(failures)):.1f}%")
print("unanswered or 'unclear' per field:", {f["id"]: sum(1 for r in failures if r["facts"].get(f["id"]) in (None, "unclear")) for f in facts_spec})

out_dir = f"{DATA}/fact_frames"; os.makedirs(out_dir, exist_ok=True)
values = "; ".join(f"{f['id']}: {'|'.join(o[0] for o in f['options'])}" for f in facts_spec)
items = []
for r in failures:
    folder, episode = r["id"].split("/")
    for camera in CAMERAS:
        video = f"{DATA}/robofac_data/realworld_data/{folder}/videos/chunk-000/observation.images.{camera}/{episode}.mp4"
        if not os.path.exists(video): continue
        with av.open(video) as c: frames = [f.to_image() for f in c.decode(video=0)]
        names = []
        for k in range(a.frames):
            name = f"{folder}_{episode}_{camera}_{k}.jpg"; frames[round(k * (len(frames) - 1) / (a.frames - 1))].save(f"{out_dir}/{name}", quality=90); names.append(f"/robot/fact_frames/{name}")
        items.append({"images": names, "system": None, "source": "annotated_facts", "type": "facts", "id": f"{r['id']}|{camera}", "task": r["task"],
                      "prompt": f"These are {a.frames} frames in time order from a video of a robotic arm. The robot's task is: {r.get('task_text') or r['task']} "
                                f"Report only what can be seen, as JSON with these fields and values: {values}.",
                      "answer": json.dumps({k: (v or "unclear") for k, v in r["facts"].items()}, ensure_ascii=False)})
json.dump(items, open(os.path.expanduser(a.out), "w"), ensure_ascii=False); print(len(items), "examples written to", a.out)
