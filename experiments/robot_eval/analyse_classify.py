"""Class-name classification results (kind "classify"): accuracy, balanced accuracy over the classes present, recall per class, what was predicted.

usage: analyse_classify.py RESULT.json [...]
"""
import collections, json, sys
for path in sys.argv[1:]:
    rows = [r for r in json.load(open(path))["results"] if r["kind"] == "classify"]
    recall, predicted = {}, collections.Counter(r["choice"] for r in rows)
    for c in sorted({r["answer"] for r in rows}):
        part = [r for r in rows if r["answer"] == c]; recall[c] = sum(r["choice"] == c for r in part) / len(part)
    acc = sum(r["choice"] == r["answer"] for r in rows) / len(rows)
    print(f"{path.split('/')[-1]:<52} n={len(rows)} acc {100*acc:4.1f}%  balanced acc {100*sum(recall.values())/len(recall):4.1f}% ({len(recall)} classes)  "
          f"recall {', '.join(f'{c.split()[0][:5]} {100*v:.0f}%' for c, v in recall.items())} | predicted {dict(predicted)}")
