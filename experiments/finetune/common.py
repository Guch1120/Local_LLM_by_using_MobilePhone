"""Prompt building shared by training and evaluation: the same prompt probe.py sends through the phone."""
import json, os
from PIL import Image

SYSTEM = ("Look at the image and decide whether the statement about it is true. "
          "Answer with JSON only: {\"assessment\": \"true\" | \"false\"}.")
ANSWER_PREFIX = '{"assessment": "'

def prompt_text(processor, row, image_dir):
    """Chat-templated prompt up to the start of the model's turn plus the JSON prefix, and the image list."""
    image = Image.open(os.path.join(image_dir, row["image"])).convert("RGB")
    messages = [
        {"role": "system", "content": [{"type": "text", "text": SYSTEM}]},
        {"role": "user", "content": [{"type": "text", "text": f"Statement: {row['caption']}"}, {"type": "image", "image": image}]},
    ]
    return processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True) + ANSWER_PREFIX, [image]

def load_rows(path):
    return json.load(open(path))
