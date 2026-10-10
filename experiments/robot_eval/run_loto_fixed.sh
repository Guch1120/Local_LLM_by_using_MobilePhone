#!/usr/bin/env bash
# The redesigned recipe (class names as answers, language LoRA, 140 tokens per frame) with a whole task held out; compare with the zero-shot
# result and with the linear probes on the same fold (Gemma 4 features: InsertCylinder 28-36%, PullCubeByTool 23-25%; DINOv2 up to 47% / 45%).
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune; R=~/data/robot/results
ev() { ./eval_robot.sh "$1" "$2" native "${3:-}" gemma-4-E2B-it-qat --max-soft-tokens 140 | cut -c1-80; python3 analyse_classify.py "$R/$1_${2}_native.json"; }
for fold in loto_insert loto_pulltool; do
  ev zs_$fold robofac_cls_$fold
  $FT/train_generic.sh F_$fold "$HOME/data/robot/mix_$fold.json" --epochs 3 --lr 1e-4 --max-soft-tokens 140 > /dev/null
  ev F_$fold robofac_cls_$fold F_$fold
done
echo all done
