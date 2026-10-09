"""Error-type (3-choice) results of eval_robot_hf.py: accuracy, balanced accuracy (mean recall of the three classes) and what was predicted.

usage: analyse_ident.py RESULT.json [...]      The real test always shows A. Orientation deviation, B. Grasping error, C. Position deviation.
"""
import collections, json, sys

for path in sys.argv[1:]:
    rows = [r for r in json.load(open(path))["results"] if r["kind"] == "mcq" and str(r["type"]).startswith("identification")]
    recall = {}
    for c in "ABC":
        part = [r for r in rows if r["answer"] == c]; recall[c] = sum(r["choice"] == c for r in part) / len(part) if part else float("nan")
    predicted = collections.Counter(r["choice"] for r in rows)
    accuracy = sum(r["choice"] == r["answer"] for r in rows) / len(rows)
    present = [v for v in recall.values() if v == v]
    print(f"{path.split('/')[-1]:<48} n={len(rows)} acc {100*accuracy:4.1f}%  balanced acc {100*sum(present)/len(present):4.1f}% (over {len(present)} classes present)  "
          f"recall A/B/C {100*recall['A']:3.0f}/{100*recall['B']:3.0f}/{100*recall['C']:3.0f}%  predicted A/B/C {predicted['A']}/{predicted['B']}/{predicted['C']}")
