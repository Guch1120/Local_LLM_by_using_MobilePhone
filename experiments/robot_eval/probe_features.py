"""Linear probes on frozen image-encoder features: is the failure type (or success) readable from the encoder output at all?

usage: probe_features.py [encoder_features.npz]
Failure type: the 480 failed episodes, 3 classes, balanced accuracy over 5 folds (an episode is never in both training and test). Success: all 602 episodes,
ROC-AUC pooled and the mean over the six tasks, 5 folds stratified by task and label. A logistic regression on standardized features, several
regularization strengths (the best one is picked on the test folds, so every number is a little optimistic; the task-only row shows the chance level).
"""
import sys, warnings, numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import balanced_accuracy_score, roc_auc_score
from sklearn.model_selection import StratifiedKFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
warnings.filterwarnings("ignore")
d = np.load(sys.argv[1] if len(sys.argv) > 1 else "/home/guch1/data/robot/results/encoder_features.npz", allow_pickle=True)
task, success, cls = d["task"], d["success"], d["error_class"]
tasks = sorted(set(task)); task_onehot = np.array([[t == k for k in tasks] for t in task], float)
fails = success == 0

def views(F):
    return {"last frame": F[:, 5], "6 frames joined": F.reshape(len(F), -1), "last - first": F[:, 5] - F[:, 0], "first, middle, last": F[:, [0, 3, 5]].reshape(len(F), -1)}

def cv_type(X, C):
    Xf, yf = X[fails], cls[fails]; strat = yf; pred = np.empty(len(yf), dtype=object)
    for tr, te in StratifiedKFold(5, shuffle=True, random_state=0).split(Xf, strat):
        m = make_pipeline(StandardScaler(), LogisticRegression(C=C, max_iter=2000, class_weight="balanced")).fit(Xf[tr], yf[tr]); pred[te] = m.predict(Xf[te])
    return balanced_accuracy_score(yf, pred)

def cv_success(X, C):
    score = np.zeros(len(success)); strat = np.array([f"{t}|{s}" for t, s in zip(task, success)])
    for tr, te in StratifiedKFold(5, shuffle=True, random_state=0).split(X, strat):
        m = make_pipeline(StandardScaler(), LogisticRegression(C=C, max_iter=2000, class_weight="balanced")).fit(X[tr], success[tr]); score[te] = m.decision_function(X[te])
    per = [roc_auc_score(success[task == t], score[task == t]) for t in tasks]
    return roc_auc_score(success, score), float(np.mean(per))

Cs = [0.0003, 0.003, 0.03]
print("chance level for the failure type: 33.3%.  task-only (one-hot) failure type balanced accuracy:", f"{100*max(cv_type(task_onehot, c) for c in Cs):.1f}%")
for name in ("gemma4", "dinov2_base", "dinov2_large"):
    F = d[name]; print(f"\n== {name}  (features per frame: {F.shape[2]})")
    print(f"{'input':<22}{'failure type, balanced acc':>28}{'success, pooled AUC':>22}{'success, mean per-task AUC':>28}")
    for view, X in views(F).items():
        t = max(cv_type(X, c) for c in Cs); s = [cv_success(X, c) for c in Cs]; best = max(s, key=lambda v: v[1])
        print(f"{view:<22}{100*t:27.1f}%{max(v[0] for v in s):22.3f}{best[1]:28.3f}")
