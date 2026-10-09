"""Error-type results on the simulation hold-out (6 classes, 3 options shown, shuffled): accuracy and balanced accuracy over the classes.

usage: analyse_sim_ident.py RESULT.json [DATA_DIR/robofac_sim_ident_eval/usable.json]
"""
import collections, json, os, re, sys

result = sys.argv[1]
items = {i["id"]: i for i in json.load(open(sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/data/robot/robofac_sim_ident_eval/usable.json")))}

def options(question):
    body = question.split("Choices:")[1].split("Please answer")[0]
    return [o.strip().rstrip(".").strip() for o in re.split(r"\s*[A-H]\.\s+", body) if o.strip()]

hit, total, predicted = collections.Counter(), collections.Counter(), collections.Counter()
for r in json.load(open(result))["results"]:
    opts = options(items[r["id"]]["question"])
    truth, guess = opts[ord(r["answer"]) - 65], opts[ord(r["choice"]) - 65]
    total[truth] += 1; hit[truth] += truth == guess; predicted[guess] += 1
n = sum(total.values())
recall = {c: hit[c] / total[c] for c in total}
chance = sum(1 / 3 * total[c] for c in total) / n
print(f"n={n} acc {100*sum(hit.values())/n:.1f}% (3 options shown, chance 33%)  balanced acc {100*sum(recall.values())/len(recall):.1f}% over {len(recall)} classes")
print("  recall:", {c: f"{100*v:.0f}%" for c, v in sorted(recall.items())}, "| predicted:", dict(predicted))
