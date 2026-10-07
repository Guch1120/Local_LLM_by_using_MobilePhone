"""QLoRA fine-tuning of Gemma 4 E2B on VSR: for an image and a statement the model answers {"assessment": "true"|"false"}.
Only the answer tokens carry loss. LoRA goes on the language model's linear layers; the vision and audio towers stay frozen."""
import argparse, random, time, torch
from transformers import AutoModelForImageTextToText, AutoProcessor, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model
from common import prompt_text, load_rows

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it")
ap.add_argument("--data", required=True, help="a folder with usable.json and images/ (train/)"); ap.add_argument("--out", required=True)
ap.add_argument("--epochs", type=float, default=1.0); ap.add_argument("--limit", type=int, default=10**9)
ap.add_argument("--accum", type=int, default=16); ap.add_argument("--lr", type=float, default=1e-4)
ap.add_argument("--rank", type=int, default=16); ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--no-4bit", action="store_true")
ap.add_argument("--exclude", default="", help="comma-separated relations left out of training (a held-out-relation test)")
ap.add_argument("--model-tag", default="")
a = ap.parse_args()
random.seed(a.seed); torch.manual_seed(a.seed)

processor = AutoProcessor.from_pretrained(a.model)
quant = None if a.no_4bit else BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16, bnb_4bit_use_double_quant=True)
model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map="cuda", quantization_config=quant)
# peft's prepare_model_for_kbit_training would cast every non-quantized weight to fp32, including the 4.7 B parameters of
# the per-layer embeddings (about 9 GB), which does not fit a 16 GB GPU. Gradient checkpointing alone is enough.
model.gradient_checkpointing_enable()
model.enable_input_require_grads()
model = get_peft_model(model, LoraConfig(r=a.rank, lora_alpha=2 * a.rank, lora_dropout=0.05, task_type="CAUSAL_LM",
        target_modules=r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)"))
model.print_trainable_parameters()

excluded = {r for r in a.exclude.split(",") if r}
rows = [r for r in load_rows(f"{a.data}/usable.json") if r["relation"] not in excluded][:a.limit]
print(f"{len(rows)} training questions; excluded relations: {sorted(excluded)}")
steps = int(len(rows) * a.epochs) // a.accum
opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=a.lr, weight_decay=0.0)
sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / 5) * max(0.0, 1 - s / max(1, steps)))
model.train(); order, losses, start = [], [], time.time()
for step in range(steps):
    for _ in range(a.accum):
        if not order: order = random.sample(range(len(rows)), len(rows))
        row = rows[order.pop()]
        text, images = prompt_text(processor, row, f"{a.data}/images")
        answer = ("true" if row["label"] else "false") + '"}<turn|>'
        prompt_len = processor(text=text, images=images, return_tensors="pt")["input_ids"].shape[1]
        batch = processor(text=text + answer, images=images, return_tensors="pt")
        labels = batch["input_ids"].clone(); labels[:, :prompt_len] = -100
        loss = model(**batch.to("cuda"), labels=labels.to("cuda")).loss / a.accum
        loss.backward(); losses.append(loss.item() * a.accum)
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    opt.step(); sched.step(); opt.zero_grad(set_to_none=True)
    if (step + 1) % 5 == 0 or step == 0:
        recent = losses[-5 * a.accum:]
        print(f"step {step+1}/{steps} loss {sum(recent)/len(recent):.4f} {time.time()-start:.0f}s", flush=True)
model.save_pretrained(a.out)
print("saved", a.out)
