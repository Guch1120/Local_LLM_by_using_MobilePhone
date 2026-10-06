"""Merge a LoRA adapter into the bf16 base model and save a plain Hugging Face checkpoint (for llama.cpp's converter)."""
import argparse, shutil, os, torch
from transformers import AutoModelForImageTextToText, AutoProcessor
from peft import PeftModel

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it"); ap.add_argument("--adapter", required=True); ap.add_argument("--out", required=True)
a = ap.parse_args()
model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map="cpu")
model = PeftModel.from_pretrained(model, a.adapter).merge_and_unload()
model.save_pretrained(a.out, safe_serialization=True)
AutoProcessor.from_pretrained(a.model).save_pretrained(a.out)
for f in ("chat_template.jinja", "generation_config.json"):
    if os.path.exists(f"{a.model}/{f}"): shutil.copy(f"{a.model}/{f}", f"{a.out}/{f}")
print("saved", a.out)
