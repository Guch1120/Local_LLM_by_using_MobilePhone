"""Frozen image-encoder features of the real RoboFAC videos (camera "above"), to ask whether the encoder holds the information at all.

usage (Docker, GPU): extract_features.py OUT.npz
For every episode, six evenly spaced frames; per frame and encoder one vector (mean over the encoder's output tokens, and the CLS token for DINO).
Encoders: gemma4 (the frozen vision tower of Gemma 4 E2B, 280-token setting), dinov2_base, dinov2_large (self-supervised, image-only).
"""
import glob, json, sys, torch, numpy as np
from PIL import Image
from transformers import AutoImageProcessor, AutoModel, AutoModelForImageTextToText, AutoProcessor

DATA = "/robot"; PICK = [0, 2, 4, 7, 9, 11]
items = [i for i in json.load(open(f"{DATA}/robofac_real12/usable.json")) if i["camera"] == "above"]
anns = {}
for path in sorted(glob.glob(f"{DATA}/robofac/test_real_*.json")): anns.update(json.load(open(path)))
cls = {}
for i in json.load(open(f"{DATA}/robofac_real/usable.json")):
    if i["type"] == "identification/above":
        body = i["question"].split("Choices:")[1].split("Please answer")[0]
        import re
        opts = [o.strip().rstrip(".").strip() for o in re.split(r"\s*[A-H]\.\s+", body) if o.strip()]
        cls[i["id"].rsplit("-", 1)[0]] = opts[ord(i["answer"]) - 65]
meta = {"ids": [i["id"] for i in items], "task": [i["task"] for i in items], "success": [int(i["answer"] == "yes") for i in items],
        "error_class": [cls.get(i["id"], "") for i in items]}
def frames(item): return [Image.open(f"{DATA}/robofac_real12/images/{item['frames'][k]}").convert("RGB") for k in PICK]
out = {}

# Gemma 4 vision tower
proc = AutoProcessor.from_pretrained("/models/hf/gemma-4-E2B-it-qat")
model = AutoModelForImageTextToText.from_pretrained("/models/hf/gemma-4-E2B-it-qat", dtype=torch.bfloat16, device_map="cuda").eval()
rows = []
with torch.no_grad():
    for item in items:
        px = proc(text="<|image|>" * len(PICK), images=frames(item), return_tensors="pt")
        feats = model.model.get_image_features(pixel_values=px["pixel_values"].to("cuda"), image_position_ids=px["image_position_ids"].to("cuda"))
        tokens = feats.last_hidden_state if hasattr(feats, "last_hidden_state") else feats
        if not rows: print("gemma4 image-feature tensor:", tuple(tokens.shape), flush=True)
        if tokens.dim() == 3: pooled = tokens.float().mean(1)                      # (frames, dim)
        else:  # the tokens of all frames in one list: split by the number of tokens per frame
            pooled = torch.stack([t.float().mean(0) for t in tokens.chunk(len(PICK))])
        rows.append(pooled.cpu().numpy())
out["gemma4"] = np.stack(rows); print("gemma4", out["gemma4"].shape, flush=True)
del model; torch.cuda.empty_cache()

for name in ("facebook/dinov2-base", "facebook/dinov2-large"):
    proc = AutoImageProcessor.from_pretrained(name); enc = AutoModel.from_pretrained(name, dtype=torch.float16).cuda().eval(); rows = []
    with torch.no_grad():
        for item in items:
            px = proc(images=frames(item), size={"height": 336, "width": 448}, do_center_crop=False, return_tensors="pt")["pixel_values"].half().cuda()
            h = enc(pixel_values=px).last_hidden_state.float()
            rows.append(torch.cat([h[:, 0], h[:, 1:].mean(1)], dim=1).cpu().numpy())
    out[name.split("/")[1].replace("-", "_")] = np.stack(rows); print(name, out[name.split("/")[1].replace("-", "_")].shape, flush=True)
    del enc; torch.cuda.empty_cache()
np.savez(sys.argv[1], **out, **{k: np.array(v) for k, v in meta.items()})
