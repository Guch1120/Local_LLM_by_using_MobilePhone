"""Error-type questions on the real RoboFAC videos with twelve evenly spaced frames (more of the motion in between).

usage: python3 prepare_robofac_ident12.py [DATA_DIR]      writes robofac_ident12/ (480 questions of camera "above"; images link to robofac_real12/images)
"""
import ast, glob, json, os, re, sys

DATA = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/robot")
OUT = f"{DATA}/robofac_ident12"; os.makedirs(OUT, exist_ok=True)
if not os.path.exists(f"{OUT}/images"): os.symlink("../robofac_real12/images", f"{OUT}/images")
frames = {i["id"]: i["frames"] for i in json.load(open(f"{DATA}/robofac_real12/usable.json"))}
anns = {}
for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))
items = []
for key, entry in anns.items():
    if "images.above" not in entry["video"] or key not in frames or "Failure identification" not in entry["annos"]: continue
    question, answer = [m["value"] for m in entry["annos"]["Failure identification"]]
    match = re.search(r"\(Your answer should choose one of the following options:\s*(\[.*?\])\)", question, re.S)
    options = ast.literal_eval(match.group(1))
    if answer.strip() not in options: continue
    lettered = " ".join(f"{chr(65 + i)}. {o}" for i, o in enumerate(options))
    body = question.replace("<image>", "").replace(match.group(0), "").strip()
    items.append({"id": f"{key}-identification12", "kind": "mcq", "type": "identification12/above", "answer": chr(65 + options.index(answer.strip())),
                  "images": frames[key], "task": entry["task"],
                  "question": f"These are twelve frames in time order from a video of a robotic arm. {body} Choices: {lettered}. "
                              "Please answer directly with only the letter of the correct option and nothing else."})
json.dump(items, open(f"{OUT}/usable.json", "w")); print(len(items), "questions")
