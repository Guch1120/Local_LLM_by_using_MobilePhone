"""Linear probes, held-out task: balanced accuracy of the failure type for each held-out task (to compare the VLM's leave-one-task-out runs with)."""
import glob, json, sys, warnings, numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import balanced_accuracy_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
warnings.filterwarnings("ignore")
d = np.load("/home/guch1/data/robot/results/encoder_features.npz", allow_pickle=True)
task, success, cls = d["task"], d["success"], d["error_class"]; fails = success == 0
for name in ("gemma4", "dinov2_base", "dinov2_large"):
    F = d[name]
    for view, X in (("last frame", F[:, 5]), ("6 frames", F.reshape(len(F), -1))):
        out = []
        for t in ("InsertCylinder", "PullCubeByTool"):
            te = fails & (task == t); tr = fails & (task != t)
            m = make_pipeline(StandardScaler(), LogisticRegression(C=0.003, max_iter=2000, class_weight="balanced")).fit(X[tr], cls[tr])
            out.append(f"{t} {100*balanced_accuracy_score(cls[te], m.predict(X[te])):.1f}%")
        print(f"{name:<13}{view:<11}", " | ".join(out))
