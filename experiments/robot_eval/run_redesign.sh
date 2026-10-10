#!/usr/bin/env bash
# Redesigned training for the error type: answer = the class name (no letters), balanced classes, 140 image tokens per frame (faster).
# Step 1, learnability on the leaky random split (a signal, including any recording-batch cue, must show up here): language LoRA only vs. with the image encoder too.
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune; R=~/data/robot/results
ev() {  # TAG FOLDER [ADAPTER]
  ./eval_robot.sh "$1" "$2" native "${3:-}" gemma-4-E2B-it-qat --max-soft-tokens 140 | cut -c1-80
  python3 analyse_classify.py "$R/$1_${2}_native.json"
}
ev zs_leaky robofac_cls_leaky
$FT/train_generic.sh L1 "$HOME/data/robot/mix_leaky.json" --epochs 3 --lr 1e-4 --max-soft-tokens 140 > /dev/null; ev L1 robofac_cls_leaky L1
$FT/train_generic.sh L2 "$HOME/data/robot/mix_leaky.json" --epochs 3 --lr 1e-4 --max-soft-tokens 140 --lora-vision > /dev/null; ev L2 robofac_cls_leaky L2
echo all done
