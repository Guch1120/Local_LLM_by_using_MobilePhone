"""A self-contained page for looking at the real RoboFAC failure videos and guessing the error type before seeing the answer.

usage: make_viewer.py OUT_BODY.html      writes the page body (no <html> wrapper); wrap it to open it locally.
Needs results/explain_base.json, results/explain_x8.json (explain.sh) and the three-choice answers of eval_robot.sh for the base model and X8.
"""
import base64, io, json, os, sys
from PIL import Image

DATA = os.path.expanduser("~/data/robot"); R = f"{DATA}/results"
JA = {"Orientation deviation": "向きのずれ", "Grasping error": "つかみの失敗", "Position deviation": "位置のずれ"}
LETTER = {"A": "Orientation deviation", "B": "Grasping error", "C": "Position deviation"}
base, x8 = json.load(open(f"{R}/explain_base.json")), {r["id"]: r for r in json.load(open(f"{R}/explain_x8.json"))}
def answers(name):
    return {r["id"]: LETTER[r["choice"]] for r in json.load(open(f"{R}/{name}"))["results"] if r["kind"] == "mcq" and r["type"] == "identification/above"}
pick_base, pick_x8 = answers("qat_robofac_real_native.json"), answers("X8id_robofac_real_native.json")

def thumb(name):
    img = Image.open(f"{DATA}/robofac_real/images/{name}").convert("RGB").resize((192, 144)); buf = io.BytesIO()
    img.save(buf, "JPEG", quality=62); return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()

order = ["InsertCylinder", "PickCubeInBox", "PullCube", "PullCubeByTool", "PushCube", "StackCube"]
items = []
for r in sorted(base, key=lambda r: (order.index(r["task"]), r["class"], r["id"])):
    items.append({"id": r["id"][:8], "task": r["task"], "task_text": r["task_text"], "label": r["class"], "ja": JA[r["class"]],
                  "frames": [thumb(n) for n in r["frames"]],
                  "base_pick": pick_base.get(r["id"]), "x8_pick": pick_x8.get(r["id"]),
                  "text": {"reference": {"what": r["reference_explanation"], "fix": r["reference_correction"]},
                           "base": {"what": r["model_explanation"], "fix": r["model_recovery"]},
                           "x8": {"what": x8[r["id"]]["model_explanation"], "fix": x8[r["id"]]["model_recovery"]}}})
for i in items:
    for k in ("reference",):
        fix = i["text"][k]["fix"]
        if isinstance(fix, list): i["text"][k]["fix"] = " ".join(fix)
    i["base_pick"] = i["base_pick"] and JA[i["base_pick"]]; i["x8_pick"] = i["x8_pick"] and JA[i["x8_pick"]]

page = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "viewer_template.html")).read().replace("__DATA__", json.dumps(items, ensure_ascii=False))
open(sys.argv[1], "w").write(page)
print(len(items), "examples,", round(len(page) / 1e6, 2), "MB")
