"""Score Gemma 4 E2B (optionally with a LoRA adapter) on a VSR sample: log p(true) - log p(false). Output works with experiments/vsr/analyse.py."""
import argparse, json, time, torch
from transformers import AutoModelForImageTextToText, AutoProcessor
from common import prompt_text, load_rows

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it"); ap.add_argument("--adapter")
ap.add_argument("--data", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--limit", type=int, default=10**9)
a = ap.parse_args()

processor = AutoProcessor.from_pretrained(a.model)
model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map="cuda")
if a.adapter:
    from peft import PeftModel
    model = PeftModel.from_pretrained(model, a.adapter)
model.eval()
tok = processor.tokenizer
true_id, false_id = tok.encode("true", add_special_tokens=False)[0], tok.encode("false", add_special_tokens=False)[0]
out, start = [], time.time()
for row in load_rows(f"{a.data}/usable.json")[:a.limit]:
    text, images = prompt_text(processor, row, f"{a.data}/images")
    inputs = processor(text=text, images=images, return_tensors="pt").to("cuda")
    with torch.no_grad():
        logprobs = torch.log_softmax(model(**inputs).logits[0, -1].float(), -1)
    out.append({"relation": row["relation"], "label": row["label"], "score": (logprobs[true_id] - logprobs[false_id]).item(),
                "p_true": logprobs[true_id].exp().item(), "p_false": logprobs[false_id].exp().item()})
json.dump({"model": a.adapter or a.model, "variant": "hf", "no_image": False, "results": out}, open(a.out, "w"))
accuracy = sum((x["score"] > 0) == bool(x["label"]) for x in out) / len(out)
print(f"{len(out)} rows, accuracy at score>0: {100*accuracy:.1f}%, {time.time()-start:.0f} s")
