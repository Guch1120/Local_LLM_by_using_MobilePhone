# Experiments

Scripts used to evaluate which vision-language model fits a robot supervisor on the phone. They are not part of the app.
Results and conclusions: `docs/2026-10-08-vsr-evaluation.md`.

- `vsr/` — Visual Spatial Reasoning (VSR, Liu et al., TACL 2023, CC BY 4.0; images from COCO, CC BY 2.0).
  - `prepare.py` downloads the data (outside the repository, default `~/data/vsr`) and builds two evaluation samples
    (165 and 162 questions) and a training set that shares no image with any test question.
  - `probe.py` asks a model on the phone about every question and records log p(true) - log p(false);
    variants: plain, two-step (describe, then judge), thinking, no-image control.
  - `analyse.py` prints accuracy at the model's own threshold, at the best threshold, and ROC-AUC by relation group.
  - `run_model.sh MODEL_ID TAG` loads a model on the phone and runs the matrix on both samples.
- `finetune/` — QLoRA fine-tuning of Gemma 4 E2B in Docker (`Dockerfile`, `train_lora.py`, `eval_hf.py`).

Delete the downloaded images when the experiments are finished.

## Export of a fine-tuned model to the phone

1. `finetune/merge.py` merges the LoRA adapter into the bf16 base and saves a Hugging Face checkpoint
   (copy the base's `tokenizer.json` and `tokenizer_config.json` over the saved ones).
2. llama.cpp's `convert_hf_to_gguf.py` writes an f16 GGUF (install only `gguf`; the converter's requirements downgrade transformers
   and break the tokenizer config), then `llama-quantize ... Q4_0`.
3. `scripts/iphone/push_model.sh model.gguf mmproj.gguf` — the vision tower is frozen, so the original mmproj is reused.
