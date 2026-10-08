#!/usr/bin/env bash
# X9: X7 again, with the VSR answers written so that only the informative tokens carry loss (a fixed JSON opening is the prefix).
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
$FT/train_generic.sh X9 "$HOME/data/robot/mix_X9.json" --epochs 2 > /dev/null
./eval_robofac_variants.sh X9 X9 --variants tasklast3 2>&1 | grep "^tasklast3" | sed "s/^/X9 /"
for s in sample1 sample2 sample3; do $FT/eval_hf.sh X9_ret "$s" X9 gemma-4-E2B-it-qat; done
./eval_robot.sh X9 robospatial_configuration native X9 2>/dev/null | cut -c1-200
./eval_robot.sh X9 robospatial_configuration json X9 2>/dev/null | cut -c1-200
echo all done
