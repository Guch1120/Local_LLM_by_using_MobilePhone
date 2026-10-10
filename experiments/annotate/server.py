"""Annotation tool for failure videos: why did the robot fail, and what should it do next?

usage: python3 server.py [--data ~/data/robot] [--port 8765] [--host 127.0.0.1] [--annotator NAME]
                        [--store FILE] [--manifest FILE --video-root DIR [--no-robofac]]

Serves one page (index.html), the two camera views of each failed RoboFAC episode (with Range requests, so the video can be scrubbed),
and stores the answers in annotations.jsonl next to this file (one JSON per line; the last line for an episode wins).
Your own videos: --manifest is a JSON list of {"id", "task", "task_text", "videos": {"wrist": "a_wrist.mp4", "side": "a_side.mp4"}} with the file names
relative to --video-root (any number of cameras, any names; the first one is the master of the playback). Skills and causes come from skills.json and taxonomy.json. Use --host 0.0.0.0 only on a network you trust: the tool has no login.
"""
import argparse, collections, glob, json, os, random, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--data", default="~/data/robot"); ap.add_argument("--port", type=int, default=8765)
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--annotator", default=os.environ.get("USER", "annotator"))
ap.add_argument("--store", default=None, help="annotation file (default: annotations.jsonl next to this script)")
ap.add_argument("--manifest", default=None); ap.add_argument("--video-root", default=None); ap.add_argument("--no-robofac", action="store_true")
args = ap.parse_args()
DATA = os.path.expanduser(args.data)
VIDEO_ROOT = os.path.realpath(f"{DATA}/robofac_data/realworld_data")
STORE = os.path.expanduser(args.store) if args.store else os.path.join(HERE, "annotations.jsonl")
CUSTOM_ROOT = os.path.realpath(os.path.expanduser(args.video_root)) if args.video_root else None
lock = threading.Lock()

def load_items():
    """One item per failed episode: the two camera videos, the task, and (hidden in the page until asked) the dataset's own label and texts."""
    anns = {}
    for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))
    episodes = collections.OrderedDict()
    for entry in anns.values():
        if "Failure identification" not in entry["annos"]: continue  # successful episodes have no failure to describe
        folder, camera, name = entry["video"].split("/")[0], entry["video"].split("/")[3].replace("observation.images.", ""), entry["video"].split("/")[-1]
        item = episodes.setdefault((folder, name), {"id": f"{folder}/{name[:-4]}", "task": entry["task"], "videos": {}})
        item["videos"][camera] = "r/" + entry["video"]
        qa = {c: [m["value"] for m in turns] for c, turns in entry["annos"].items()}
        item["task_text"] = qa["Task identification"][1].strip()
        item["dataset"] = {"class": qa["Failure identification"][1].strip(), "explanation": qa.get("Failure explanation", ["", ""])[1],
                           "correction": qa.get("High-level correction", ["", ""])[1]}
    items = [i for i in episodes.values() if "above" in i["videos"]] if not args.no_robofac and os.path.isdir(VIDEO_ROOT) else []
    by_task = collections.defaultdict(list)
    for i in items: by_task[i["task"]].append(i)
    rnd = random.Random(7)
    for v in by_task.values(): rnd.shuffle(v)
    ordered = []  # round-robin over tasks, so any prefix of the list covers every task
    while any(by_task.values()):
        for task in sorted(by_task):
            if by_task[task]: ordered.append(by_task[task].pop())
    custom = []
    if args.manifest:
        for item in json.load(open(os.path.expanduser(args.manifest))):
            item["videos"] = {cam: "c/" + path for cam, path in item["videos"].items()}
            item.setdefault("task", "custom"); item.setdefault("task_text", ""); custom.append(item)
    return custom + ordered

ITEMS = load_items()
KNOWN = {i["id"] for i in ITEMS}

def saved():
    done = {}
    if os.path.exists(STORE):
        for line in open(STORE):
            try: record = json.loads(line)
            except ValueError: continue
            done[record["id"]] = record
    return done

def json_bytes(obj): return json.dumps(obj, ensure_ascii=False).encode()

class Handler(BaseHTTPRequestHandler):
    server_version = "annotate/1"
    def log_message(self, *a): pass
    def send_bytes(self, data, ctype, status=200, extra=None):
        self.send_response(status); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path == "/": return self.send_bytes(open(f"{HERE}/index.html", "rb").read(), "text/html; charset=utf-8")
        if path == "/api/config":
            return self.send_bytes(json_bytes({"annotator": args.annotator, "skills": json.load(open(f"{HERE}/skills.json"))["skills"],
                                               "causes": json.load(open(f"{HERE}/taxonomy.json"))["causes"]}), "application/json")
        if path == "/api/items": return self.send_bytes(json_bytes({"items": ITEMS, "saved": saved()}), "application/json")
        if path.startswith("/video/"): return self.send_video(path[len("/video/"):])
        self.send_bytes(b"not found", "text/plain", 404)
    def do_POST(self):
        if urlparse(self.path).path != "/api/annotate": return self.send_bytes(b"not found", "text/plain", 404)
        record = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if record.get("id") not in KNOWN: return self.send_bytes(b"unknown episode", "text/plain", 400)
        record["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        with lock, open(STORE, "a") as f: f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.send_bytes(b'{"ok": true}', "application/json")
    def send_video(self, relative):
        kind, _, relative = relative.partition("/")
        root = {"r": VIDEO_ROOT, "c": CUSTOM_ROOT}.get(kind)
        if not root: return self.send_bytes(b"not found", "text/plain", 404)
        full = os.path.realpath(os.path.join(root, relative))
        if not full.startswith(root + os.sep) or not os.path.isfile(full): return self.send_bytes(b"not found", "text/plain", 404)
        size = os.path.getsize(full); start, end = 0, size - 1
        match = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if match:
            if match.group(1): start = int(match.group(1))
            if match.group(2): end = min(int(match.group(2)), size - 1)
            if not match.group(1) and match.group(2): start, end = max(0, size - int(match.group(2))), size - 1
        with open(full, "rb") as f: f.seek(start); data = f.read(end - start + 1)
        self.send_bytes(data, "video/mp4", 206 if match else 200,
                        {"Accept-Ranges": "bytes", "Content-Range": f"bytes {start}-{end}/{size}"} if match else {"Accept-Ranges": "bytes"})

if __name__ == "__main__":
    print(f"{len(ITEMS)} failed episodes, {len(saved())} already annotated. Open http://{args.host}:{args.port}/  (annotations: {STORE})")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
