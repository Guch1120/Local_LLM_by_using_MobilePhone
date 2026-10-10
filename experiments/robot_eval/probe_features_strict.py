"""Linear probes again, with splits that cannot use the recording batch as a shortcut.

The real episodes were recorded in blocks of 20 with the same outcome (for example 20 grasping errors in a row), so a random split puts neighbours
of the same block into training and test. Here (1) whole blocks of 20 episodes are held out, (2) a whole task is held out (trained on the other five).
usage: probe_features_strict.py [encoder_features.npz]
"""
import glob, json, re, sys, warnings, numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import balanced_accuracy_score, roc_auc_score
from sklearn.model_selection import GroupKFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
warnings.filterwarnings("ignore")
DATA = "/home/guch1/data/robot"
d = np.load(sys.argv[1] if len(sys.argv) > 1 else f"{DATA}/results/encoder_features.npz", allow_pickle=True)
anns = {}
for p in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(p)))
episode = {k: int(re.search(r"episode_(\d+)", e["video"]).group(1)) for k, e in anns.items() if "images.above" in e["video"]}
task, success, cls = d["task"], d["success"], d["error_class"]
block = np.array([f"{t}|{episode[i] // 20}" for t, i in zip(task, d["ids"])])
fails = success == 0
C = 0.003
def model(): return make_pipeline(StandardScaler(), LogisticRegression(C=C, max_iter=2000, class_weight="balanced"))

def type_scores(X, groups):
    Xf, yf, g = X[fails], cls[fails], groups[fails]; pred = np.empty(len(yf), dtype=object); n = len(set(g))
    for tr, te in GroupKFold(min(5, n)).split(Xf, yf, g): pred[te] = model().fit(Xf[tr], yf[tr]).predict(Xf[te])
    return balanced_accuracy_score(yf, pred)

def success_scores(X, groups):
    score = np.zeros(len(success)); n = len(set(groups))
    for tr, te in GroupKFold(min(5, n)).split(X, success, groups): score[te] = model().fit(X[tr], success[tr]).decision_function(X[te])
    return roc_auc_score(success, score), float(np.mean([roc_auc_score(success[task == t], score[task == t]) for t in sorted(set(task))]))

print("failure type: chance 33.3%;  success AUC: chance 0.5.   C =", C)
for name in ("gemma4", "dinov2_base", "dinov2_large"):
    F = d[name]
    for view, X in (("last frame", F[:, 5]), ("6 frames joined", F.reshape(len(F), -1))):
        a = type_scores(X, block); b = type_scores(X, task); c = success_scores(X, block); e = success_scores(X, task)
        print(f"{name:<13}{view:<17} failure type: held-out blocks {100*a:4.1f}%, held-out task {100*b:4.1f}% | success AUC: held-out blocks {c[0]:.3f} (per task {c[1]:.3f}), held-out task {e[0]:.3f} (per task {e[1]:.3f})")
