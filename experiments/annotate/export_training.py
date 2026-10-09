"""Turn annotations.jsonl into a training list (a JSON list for experiments/finetune/train_generic.py) and a summary.

usage: export_training.py [--out ~/data/robot/mix_annotated.json] [--frames 8] [--window 1.0]
For every episode marked as a failure the frames come from the time of the failure (t_fail +- window seconds), eight of them, both cameras' "above" view;
without a time they are spread over the whole video. The answer is a JSON text with the cause tags, a short description and the recovery plan.
Needs the videos under ~/data/robot/robofac_data/realworld_data and the frames are written to ~/data/robot/annotated_frames/.
"""
import argparse, collections, json, os
import av

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="~/data/robot/mix_annotated.json"); ap.add_argument("--frames", type=int, default=8); ap.add_argument("--window", type=float, default=1.0)
a = ap.parse_args()
DATA = os.path.expanduser("~/data/robot"); HERE = os.path.dirname(os.path.abspath(__file__))
records = {}
for line in open(f"{HERE}/annotations.jsonl"):
    r = json.loads(line); records[r["id"]] = r
failures = [r for r in records.values() if r.get("visible") == "failure"]
print(f"{len(records)} annotated episodes, {len(failures)} marked as a failure; causes:", dict(collections.Counter(c for r in failures for c in r["causes"])))
print("skills used:", dict(collections.Counter(p["skill"] for r in failures for p in r["plan"]).most_common()))
print("missing skills named:", [r["missing_skill"] for r in failures if r["missing_skill"]][:20])
out_dir = f"{DATA}/annotated_frames"; os.makedirs(out_dir, exist_ok=True)
items = []
for r in failures:
    folder, episode = r["id"].split("/")
    video = f"{DATA}/robofac_data/realworld_data/{folder}/videos/chunk-000/observation.images.above/{episode}.mp4"
    with av.open(video) as c:
        stream = c.streams.video[0]; frames = [(float(f.pts * stream.time_base), f.to_image()) for f in c.decode(video=0)]
    t0, t1 = (r["t_fail"] - a.window, r["t_fail"] + a.window) if r.get("t_fail") is not None else (frames[0][0], frames[-1][0])
    pool = [f for f in frames if t0 <= f[0] <= t1] or frames
    names = []
    for k in range(a.frames):
        t, img = pool[round(k * (len(pool) - 1) / max(1, a.frames - 1))]
        name = f"{folder}_{episode}_{k}.jpg"; img.save(f"{out_dir}/{name}", quality=90); names.append(f"/robot/annotated_frames/{name}")
    answer = json.dumps({"causes": r["causes"], "what_happened": r["what_happened"],
                         "recovery": [{"skill": p["skill"], "params": p["note"]} for p in r["plan"]], "change_to_avoid_repeating": r["avoid_repeat"]}, ensure_ascii=False)
    items.append({"images": names, "system": None, "source": "annotated", "type": "recovery", "answer": answer,
                  "prompt": f"These are {a.frames} frames in time order from a video of a robotic arm. The robot's task is: TASK. The task failed. "
                            "Describe the cause of the failure and give a recovery plan as JSON."})
json.dump(items, open(os.path.expanduser(a.out), "w"), ensure_ascii=False)
print(len(items), "training examples written to", a.out)
