"""QLoRA fine-tuning of Gemma 4 E2B on a list of examples: any number of images, an optional system prompt, a prompt and an answer.
Only the answer (and the end of the turn) carries loss. Same recipe as train_lora.py; build the list with
experiments/robot_eval/build_mix.py.

examples file: [{"images": ["/robot/....jpg", ...], "system": "..." or null, "prompt": "...", "answer": "...", "prefix": "..."}]
"prefix" (optional) is written at the start of the model's turn and carries no loss; use it for fixed text such as the JSON
opening, so that the loss falls on the informative tokens only (train_lora.py does the same for VSR).
"""
import argparse, json, random, time, torch
from PIL import Image
from transformers import AutoModelForImageTextToText, AutoProcessor, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="/models/hf/gemma-4-E2B-it-qat")
ap.add_argument("--examples", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--epochs", type=float, default=1.0); ap.add_argument("--limit", type=int, default=10**9)
ap.add_argument("--accum", type=int, default=16); ap.add_argument("--lr", type=float, default=1e-4)
ap.add_argument("--rank", type=int, default=16); ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--init-adapter", help="continue from this adapter instead of a fresh one")
ap.add_argument("--lora-vision", action="store_true", help="also put LoRA on the image encoder's linear layers (the language model's are always trained)")
ap.add_argument("--max-soft-tokens", type=int, default=0, help="image token budget per frame (default: the processor's 280)")
a = ap.parse_args()
random.seed(a.seed); torch.manual_seed(a.seed)

processor = AutoProcessor.from_pretrained(a.model)
if a.max_soft_tokens: processor.image_processor.max_soft_tokens = a.max_soft_tokens
quant = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=torch.bfloat16, bnb_4bit_use_double_quant=True)
model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map="cuda", quantization_config=quant)
model.gradient_checkpointing_enable()
model.enable_input_require_grads()
if a.init_adapter:
    from peft import PeftModel
    model = PeftModel.from_pretrained(model, a.init_adapter, is_trainable=True)
else:
    model = get_peft_model(model, LoraConfig(r=a.rank, lora_alpha=2 * a.rank, lora_dropout=0.05, task_type="CAUSAL_LM",
            target_modules=(r"(?:.*language_model.*\.(?:q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj))|"
                            r"(?:.*vision_tower.*\.(?:q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)\.linear)") if a.lora_vision
            else r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)"))
model.print_trainable_parameters()

examples = json.load(open(a.examples))[:a.limit]
steps = int(len(examples) * a.epochs) // a.accum
print(f"{len(examples)} examples, {steps} optimizer steps", flush=True)
opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=a.lr, weight_decay=0.0)
sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / 5) * max(0.0, 1 - s / max(1, steps)))

def encode(example):
    images = [Image.open(p).convert("RGB") for p in example["images"]]
    content = [{"type": "image", "image": im} for im in images] + [{"type": "text", "text": example["prompt"]}]
    messages = ([{"role": "system", "content": [{"type": "text", "text": example["system"]}]}] if example.get("system") else []) \
        + [{"role": "user", "content": content}]
    prompt = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True) + example.get("prefix", "")
    prompt_len = processor(text=prompt, images=images, return_tensors="pt")["input_ids"].shape[1]
    batch = processor(text=prompt + example["answer"] + "<turn|>", images=images, return_tensors="pt")
    labels = batch["input_ids"].clone(); labels[:, :prompt_len] = -100
    return batch, labels

model.train(); order, losses, start = [], [], time.time()
for step in range(steps):
    for _ in range(a.accum):
        if not order: order = random.sample(range(len(examples)), len(examples))
        batch, labels = encode(examples[order.pop()])
        loss = model(**batch.to("cuda"), labels=labels.to("cuda")).loss / a.accum
        loss.backward(); losses.append(loss.item() * a.accum)
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    opt.step(); sched.step(); opt.zero_grad(set_to_none=True)
    if (step + 1) % 5 == 0 or step == 0:
        recent = losses[-5 * a.accum:]
        print(f"step {step+1}/{steps} loss {sum(recent)/len(recent):.4f} {time.time()-start:.0f}s", flush=True)
model.save_pretrained(a.out)
print("saved", a.out)
