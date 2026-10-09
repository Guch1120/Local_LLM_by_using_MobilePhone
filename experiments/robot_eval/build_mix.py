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
import argparse, collections, json, os, random, re

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--det-pos", type=int, default=10**9); ap.add_argument("--det-neg-ratio", type=float, default=1.0)
ap.add_argument("--ident", type=int, default=10**9); ap.add_argument("--vsr", type=int, default=0)
ap.add_argument("--frames", default="even6", choices=["even6", "last3", "even12", "firstlast", "last1", "last2", "last6", "gap4"]); ap.add_argument("--ident-frames", default=None, choices=[None, "even6", "last3", "even12", "firstlast", "last1", "last2", "last6", "gap4"], help="frames for the error-type examples (default: same as --frames)")
ap.add_argument("--exclude-tasks", default="", help="comma-separated simulation task families left out of the RoboFAC examples (a held-out-task test)")
ap.add_argument("--ident-per-class", type=int, default=0, help="error-type examples per class (0: all examples as they are); small classes are drawn again with new option orders")
ap.add_argument("--ident-choices", type=int, default=0, help="number of options shown in an error-type question (0: as stored); the correct one plus random others, in random order")
ap.add_argument("--holdout-ident", type=int, default=0, help="set this many error-type videos aside (never trained on) and write them as a test folder robofac_sim_ident_eval")
ap.add_argument("--task-text", action="store_true")
ap.add_argument("--only-with-task-text", action="store_true", help="keep only detection examples that have a task description, whether or not the prompt shows it (a fair control)")
ap.add_argument("--vsr-full-answer", action="store_true", help="old format: the whole JSON answer carries loss (dilutes the informative token)")
ap.add_argument("--seed", type=int, default=0)
a = ap.parse_args()
rnd = random.Random(a.seed)
PICK = {"even6": [0, 2, 4, 7, 9, 11], "last3": [9, 10, 11], "firstlast": [0, 11], "even12": list(range(12)),
        "last1": [11], "last2": [10, 11], "last6": [6, 7, 8, 9, 10, 11], "gap4": [5, 7, 9, 11]}
WORDS = {2: "two", 3: "three", 4: "four", 6: "six", 12: "twelve"}
VSR_SYSTEM = ("Look at the image and decide whether the statement about it is true. "
              "Answer with JSON only: {\"assessment\": \"true\" | \"false\"}.")
DATA = os.path.expanduser("~/data")

robofac = json.load(open(f"{DATA}/robot/robofac_train/usable.json"))
excluded_tasks = {t for t in a.exclude_tasks.split(",") if t}
robofac = [i for i in robofac if i["task"].split("-")[0] not in excluded_tasks]
idx = PICK[a.frames]
lead = ("This is one frame from a video of a robotic arm. " if len(idx) == 1
        else f"These are {WORDS[len(idx)]} frames in time order from a video of a robotic arm. ")

def example(item, prompt, answer, picks=None):
    return {"images": [f"/robot/robofac_train/images/{item['frames'][k]}" for k in (picks or idx)], "system": None, "prompt": prompt, "answer": answer,
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
held_out = []
if a.holdout_ident:
    held_out, ident = ident[:a.holdout_ident], ident[a.holdout_ident:]
ident_idx = PICK[a.ident_frames or a.frames]
ident_lead = ("This is one frame from a video of a robotic arm. " if len(ident_idx) == 1
              else f"These are {WORDS[len(ident_idx)]} frames in time order from a video of a robotic arm. ")

def parse_choices(question):
    """(text before 'Choices:', options without their letters and trailing period) of an error-type question."""
    body, rest = question.split(" Choices: ", 1)
    rest = rest.split(" Please answer")[0]
    return body, [o.strip().rstrip(".").strip() for o in re.split(r"\s*[A-H]\.\s+", rest) if o.strip()]

def rebuild(question, answer_letter):
    """A question with the options in a new random order and, optionally, a random subset (the correct option always stays)."""
    body, options = parse_choices(question)
    correct = options[ord(answer_letter) - 65]
    others = [o for o in options if o != correct]
    if a.ident_choices: others = rnd.sample(others, min(a.ident_choices - 1, len(others)))
    shown = [correct] + others; rnd.shuffle(shown)
    lettered = " ".join(f"{chr(65 + k)}. {o}." for k, o in enumerate(shown))
    return (f"{body} Choices: {lettered}. Please answer directly with only the letter of the correct option and nothing else.",
            chr(65 + shown.index(correct)))

chosen = ident[:a.ident]
if a.ident_per_class:
    by_class = collections.defaultdict(list)
    for item in ident:
        body, options = parse_choices(item["question"]); by_class[options[ord(item["answer"]) - 65]].append(item)
    chosen = [x for items in by_class.values() for x in rnd.choices(items, k=a.ident_per_class)]
for item in chosen:
    question, answer = (rebuild(item["question"], item["answer"]) if (a.ident_choices or a.ident_per_class) else (item["question"], item["answer"]))
    out.append(example(item, ident_lead + question, answer, ident_idx))
if a.vsr:
    rows = json.load(open(f"{DATA}/vsr/train/usable.json")); rnd.shuffle(rows)
    for r in rows[:a.vsr]:
        verdict = "true" if r["label"] else "false"
        example_vsr = {"images": [f"/data/vsr/train/images/{r['image']}"], "system": VSR_SYSTEM, "prompt": f"Statement: {r['caption']}",
                       "source": "vsr", "type": "vsr"}
        if a.vsr_full_answer:
            example_vsr["answer"] = '{"assessment": "%s"}' % verdict
        else:
            example_vsr["prefix"], example_vsr["answer"] = '{"assessment": "', verdict + '"}'
        out.append(example_vsr)
if held_out:
    folder = f"{DATA}/robot/robofac_sim_ident_eval"; os.makedirs(folder, exist_ok=True)
    if not os.path.exists(f"{folder}/images"): os.symlink("../robofac_train/images", f"{folder}/images")
    tests = []
    for item in held_out:
        question, answer = rebuild(item["question"], item["answer"])
        tests.append({"id": item["id"], "kind": "mcq", "type": "identification/sim", "answer": answer, "question": ident_lead + question,
                      "images": [item["frames"][k] for k in ident_idx], "task": item["task"]})
    json.dump(tests, open(f"{folder}/usable.json", "w"))
    held_ids = {i["id"] for i in held_out}
    print(len(tests), "error-type videos held out for the simulation test")
rnd.shuffle(out)
json.dump(out, open(a.out, "w"))
print(len(out), "examples:", dict(collections.Counter((e["source"], e["type"], e["answer"] if e["type"] == "detection" else "-") for e in out)))
