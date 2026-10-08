"""Build a training list (for experiments/finetune/train_generic.py) from RoboFAC simulation examples and/or VSR.

usage: build_mix.py OUT.json [--det-pos N] [--det-neg-ratio R] [--ident N] [--vsr N] [--frames even6|last3|even12|firstlast]
                             [--task-text] [--seed S]
  --det-pos       success-detection examples with the answer yes (all of them by default; 0 turns detection off)
  --det-neg-ratio failures per success in the detection examples (1 = balanced)
  --ident         error-type multiple-choice examples (0 = none, default all)
  --vsr           examples of the VSR true/false task (the format the first adapter was trained on), 0 = none
  --task-text     the prompt states the robot's task (as the "task6" evaluation variant does)
The prompts are the ones eval_robot_hf.py / eval_robofac_variants.py use, so training and test see the same wording.
Paths are the ones inside the Docker container (~/data/robot -> /robot, ~/data/vsr -> /data/vsr).
"""
import argparse, json, os, random

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--det-pos", type=int, default=10**9); ap.add_argument("--det-neg-ratio", type=float, default=1.0)
ap.add_argument("--ident", type=int, default=10**9); ap.add_argument("--vsr", type=int, default=0)
ap.add_argument("--frames", default="even6", choices=["even6", "last3", "even12", "firstlast"]); ap.add_argument("--task-text", action="store_true")
ap.add_argument("--only-with-task-text", action="store_true", help="keep only detection examples that have a task description, whether or not the prompt shows it (a fair control)")
ap.add_argument("--seed", type=int, default=0)
a = ap.parse_args()
rnd = random.Random(a.seed)
PICK = {"even6": [0, 2, 4, 7, 9, 11], "last3": [9, 10, 11], "firstlast": [0, 11], "even12": list(range(12))}
WORDS = {2: "two", 3: "three", 6: "six", 12: "twelve"}
VSR_SYSTEM = ("Look at the image and decide whether the statement about it is true. "
              "Answer with JSON only: {\"assessment\": \"true\" | \"false\"}.")
DATA = os.path.expanduser("~/data")

robofac = json.load(open(f"{DATA}/robot/robofac_train/usable.json"))
idx = PICK[a.frames]
lead = f"These are {WORDS[len(idx)]} frames in time order from a video of a robotic arm. "

def example(item, prompt, answer):
    return {"images": [f"/robot/robofac_train/images/{item['frames'][k]}" for k in idx], "system": None, "prompt": prompt, "answer": answer,
            "source": "robofac", "type": item["type"]}

out = []
pos = [i for i in robofac if i["type"] == "detection" and i["answer"] == "yes"]; neg = [i for i in robofac if i["type"] == "detection" and i["answer"] == "no"]
rnd.shuffle(pos); rnd.shuffle(neg)
if a.only_with_task_text or a.task_text:
    pos = [i for i in pos if i["task_text"]]; neg = [i for i in neg if i["task_text"]]
pos = pos[:a.det_pos]; neg = neg[:int(len(pos) * a.det_neg_ratio)]
for item in pos + neg:
    if a.only_with_task_text and not item["task_text"]: continue
    if a.task_text:
        if not item["task_text"]: continue
        prompt = lead + f"The robot's task is: {item['task_text']} Was the task completed successfully? Answer yes or no."
    else:
        prompt = lead + item["question"] + " Answer yes or no."
    out.append(example(item, prompt, "Yes" if item["answer"] == "yes" else "No"))
ident = [i for i in robofac if i["type"] == "identification"]; rnd.shuffle(ident)
for item in ident[:a.ident]:
    out.append(example(item, lead + item["question"], item["answer"]))
if a.vsr:
    rows = json.load(open(f"{DATA}/vsr/train/usable.json")); rnd.shuffle(rows)
    for r in rows[:a.vsr]:
        out.append({"images": [f"/data/vsr/train/images/{r['image']}"], "system": VSR_SYSTEM, "prompt": f"Statement: {r['caption']}",
                    "answer": '{"assessment": "%s"}' % ("true" if r["label"] else "false"), "source": "vsr", "type": "vsr"})
rnd.shuffle(out)
json.dump(out, open(a.out, "w"))
import collections
print(len(out), "examples:", dict(collections.Counter((e["source"], e["type"], e["answer"] if e["type"] == "detection" else "-") for e in out)))
