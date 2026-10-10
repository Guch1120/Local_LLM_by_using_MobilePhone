"""Download the RoboFAC real-robot failure videos and their annotations for the annotation tool (about 2.2 GB), for example on another computer.

usage: python3 fetch_data.py [--data ~/data/robot]        needs: pip install huggingface_hub   (pip install hf_xet makes it faster)
Writes   DATA/robofac/test_real_0..6.json          the annotations of the real-robot episodes
         DATA/robofac_data/realworld_data/...      the videos (AV1; Chrome and Firefox play them)
The Hub answers "429 Too Many Requests" when many files are requested at once; the script retries slowly.
"""
import argparse, os, time
from huggingface_hub import hf_hub_download, snapshot_download

ap = argparse.ArgumentParser(); ap.add_argument("--data", default="~/data/robot"); a = ap.parse_args()
DATA = os.path.expanduser(a.data); REPO = "MINT-SJTU/RoboFAC-dataset"
os.makedirs(f"{DATA}/robofac", exist_ok=True)
for i in range(7):
    target = f"{DATA}/robofac/test_real_{i}.json"
    if os.path.exists(target): continue
    cached = hf_hub_download(REPO, f"test_qa_realworld/annos_per_video_split{i}.json", repo_type="dataset")
    with open(cached, "rb") as src, open(target, "wb") as dst: dst.write(src.read())
for attempt in range(8):
    try:
        snapshot_download(REPO, repo_type="dataset", allow_patterns=["realworld_data/**"], local_dir=f"{DATA}/robofac_data", max_workers=2); break
    except Exception as e:
        print("retrying after", repr(e)[:100]); time.sleep(10 * (attempt + 1))
print("done:", DATA)
