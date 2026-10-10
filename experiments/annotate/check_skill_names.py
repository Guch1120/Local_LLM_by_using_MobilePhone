"""Check that no two skill names (or class names) start with the same token, with and without a leading space.

usage (Docker, the tokenizer of the model): check_skill_names.py [skills.json] [--model /models/hf/gemma-4-E2B-it-qat]
A name that starts like another one cannot be told apart by its first token; the evaluation then has to compare whole names (full-name scoring,
which is always used for the final decision), but distinct first tokens also make the model's first step cheaper to learn.
"""
import argparse, collections, json, os
from transformers import AutoTokenizer

ap = argparse.ArgumentParser(); ap.add_argument("skills", nargs="?", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "skills.json"))
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it-qat"); a = ap.parse_args()
tok = AutoTokenizer.from_pretrained(a.model)
ids = [s["id"] for s in json.load(open(a.skills))["skills"]]
first = collections.defaultdict(set)
for name in ids:
    for variant in (name, " " + name):   # the opening quote of a JSON string is context, not part of the name
        first[name].add(tok.encode(variant, add_special_tokens=False)[0])
owners = collections.defaultdict(list)
for name, toks in first.items():
    for t in toks: owners[t].append(name)
clash = {tok.convert_ids_to_tokens([t])[0]: names for t, names in owners.items() if len(set(names)) > 1}
for name in ids: print(f"{name:<26}", tok.convert_ids_to_tokens(tok.encode(name, add_special_tokens=False)))
print("\nNAMES THAT START WITH THE SAME TOKEN:", clash if clash else "none")
