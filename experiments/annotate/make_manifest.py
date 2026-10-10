"""Make a manifest for the annotation tool from a folder of your own videos.

usage: make_manifest.py VIDEO_DIR OUT.json [--task NAME] [--task-text "what the robot was asked to do"]
File names are  <episode>__<camera>.mp4  (two underscores), for example  pick01__wrist.mp4  and  pick01__side.mp4  for one episode seen by two cameras.
Run the tool with:  python3 server.py --manifest OUT.json --video-root VIDEO_DIR --store ~/annotations_mine.jsonl --no-robofac
The task text of each episode can be edited in the manifest afterwards; it is shown above the videos, so write what the robot was supposed to do.
"""
import argparse, collections, json, os, re

ap = argparse.ArgumentParser()
ap.add_argument("video_dir"); ap.add_argument("out"); ap.add_argument("--task", default="custom"); ap.add_argument("--task-text", default="")
a = ap.parse_args()
episodes = collections.defaultdict(dict)
for name in sorted(os.listdir(os.path.expanduser(a.video_dir))):
    m = re.match(r"(.+?)__(.+?)\.(mp4|webm|mov)$", name)
    if m: episodes[m.group(1)][m.group(2)] = name
items = [{"id": f"mine/{ep}", "task": a.task, "task_text": a.task_text, "videos": cams} for ep, cams in sorted(episodes.items())]
json.dump(items, open(os.path.expanduser(a.out), "w"), ensure_ascii=False, indent=1)
print(len(items), "episodes;", "cameras:", sorted({c for i in items for c in i["videos"]}))
