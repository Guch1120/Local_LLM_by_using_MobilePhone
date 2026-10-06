"""Accuracy at the model's own threshold, at the best threshold, and ROC-AUC (overall and by relation group) from probe.py output."""
import json, sys

GROUPS = {"left/right": ["at the left side of", "at the right side of"],
          "above/below/behind": ["above", "below", "under", "behind", "in front of"],
          "contact/near": ["touching", "on", "beside", "next to", "near"],
          "containment": ["inside", "contains"]}

def auc(rows):
    pos = [x["score"] for x in rows if x["label"]]; neg = [x["score"] for x in rows if not x["label"]]
    if not pos or not neg: return float("nan")
    return sum((p > q) + 0.5 * (p == q) for p in pos for q in neg) / (len(pos) * len(neg))

def analyse(path):
    d = json.load(open(path)); r = d["results"]; n = len(r)
    own = sum((x["score"] > 0) == bool(x["label"]) for x in r) / n
    scores = sorted({x["score"] for x in r})
    cands = [scores[0] - 1] + [(a + b) / 2 for a, b in zip(scores, scores[1:])] + [scores[-1] + 1]
    best = max((sum((x["score"] > t) == bool(x["label"]) for x in r) / n, t) for t in cands)
    name = f"{d['model']} {d.get('variant', 'base')}{' think' if d.get('think') else ''}{' no-image' if d['no_image'] else ''}"
    groups = "  ".join(f"{g} {auc([x for x in r if x['relation'] in rel]):.2f}" for g, rel in GROUPS.items())
    secs = d.get("seconds") or [0]
    print(f"{name:<52} n={n:<3} own {100*own:4.1f}% (says true {100*sum(x['score'] > 0 for x in r)/n:3.0f}%)  "
          f"best {100*best[0]:4.1f}%  AUC {auc(r):.3f}  {sum(secs)/len(secs):4.1f} s/q  | {groups}")

for p in sys.argv[1:]: analyse(p)
