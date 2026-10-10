"""Registry of observable predicates (predicates.json): list, validate, add, deprecate.

usage: predicates.py list [--layer L] [--status S]
       predicates.py check
       predicates.py add ID --layer L --question "..." [--args a b] [--definition "..."] [--sim auto|human|none] [--note "..."]
       predicates.py status ID active|proposed|deprecated [--note "reason"]
       predicates.py questions [--status active]   # the Yes/No questions, as the model will see them
Nothing is ever deleted: a predicate that is no longer wanted gets status 'deprecated', so the ids in old training data and logs stay valid.
Every change appends a line to the changelog and bumps the version.
"""
import argparse, json, os, re, sys, time

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "predicates.json")
LAYERS = {"state", "event", "self"}; STATUS = {"proposed", "active", "deprecated"}; SIM = {"auto", "human", "none"}

def load(): return json.load(open(PATH))
def save(d): json.dump(d, open(PATH, "w"), ensure_ascii=False, indent=2); open(PATH, "a").write("\n")

def check(d):
    problems, seen = [], set()
    for p in d["predicates"]:
        i = p["id"]
        if i in seen: problems.append(f"duplicate id {i}")
        seen.add(i)
        if not re.fullmatch(r"[a-z][a-z0-9_]*", i): problems.append(f"{i}: id must be snake_case")
        if p["layer"] not in LAYERS: problems.append(f"{i}: layer {p['layer']}")
        if p["status"] not in STATUS: problems.append(f"{i}: status {p['status']}")
        if p["sim"] not in SIM: problems.append(f"{i}: sim {p['sim']}")
        holes = set(re.findall(r"{(\w+)}", p["question"]))
        if p["layer"] != "self" and not p["question"]: problems.append(f"{i}: question is empty")
        if holes != set(p["args"]): problems.append(f"{i}: question placeholders {sorted(holes)} do not match args {p['args']}")
        if p["layer"] == "self" and p["question"]: problems.append(f"{i}: self predicates are not asked of the model")
    return problems

def log(d, text):
    d["version"] += 1; d["changelog"].append({"date": time.strftime("%Y-%m-%d"), "version": d["version"], "change": text})

def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("list"); s.add_argument("--layer"); s.add_argument("--status")
    sub.add_parser("check")
    s = sub.add_parser("add"); s.add_argument("id"); s.add_argument("--layer", required=True); s.add_argument("--question", default="")
    s.add_argument("--args", nargs="*", default=["a"]); s.add_argument("--definition", default=""); s.add_argument("--sim", default="human"); s.add_argument("--note", default="")
    s = sub.add_parser("status"); s.add_argument("id"); s.add_argument("value"); s.add_argument("--note", default="")
    s = sub.add_parser("questions"); s.add_argument("--status", default="active")
    a = ap.parse_args(); d = load()
    if a.cmd == "list":
        for p in d["predicates"]:
            if (not a.layer or p["layer"] == a.layer) and (not a.status or p["status"] == a.status):
                print(f"{p['id']:<22}{p['layer']:<7}{p['status']:<11}sim={p['sim']:<6}{p['question'] or '(sensor)'}")
    elif a.cmd == "check":
        problems = check(d); print("\n".join(problems) or f"ok: {len(d['predicates'])} predicates, version {d['version']}"); sys.exit(1 if problems else 0)
    elif a.cmd == "add":
        if any(p["id"] == a.id for p in d["predicates"]): sys.exit(f"{a.id} already exists (ids are never reused)")
        d["predicates"].append({"id": a.id, "layer": a.layer, "args": a.args if a.layer != "self" else [], "question": a.question, "sim": a.sim,
                                "definition": a.definition, "params": {}, "status": "proposed", "since": time.strftime("%Y-%m-%d"), "note": a.note})
        problems = check(d)
        if problems: sys.exit("\n".join(problems))
        log(d, f"added {a.id} (proposed)"); save(d); print("added", a.id)
    elif a.cmd == "status":
        p = next((p for p in d["predicates"] if p["id"] == a.id), None)
        if not p: sys.exit("unknown id")
        if a.value not in STATUS: sys.exit(f"status must be one of {sorted(STATUS)}")
        if a.value == "deprecated" and not a.note: sys.exit("give the reason with --note")
        p["status"] = a.value; p["note"] = a.note or p["note"]; log(d, f"{a.id}: {a.value}" + (f" ({a.note})" if a.note else "")); save(d); print(a.id, "->", a.value)
    elif a.cmd == "questions":
        for p in d["predicates"]:
            if p["status"] == a.status and p["question"]: print(f"{p['id']}: {p['question']}")

if __name__ == "__main__": main()
