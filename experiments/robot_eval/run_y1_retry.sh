#!/usr/bin/env bash
# Y1 again: the error-type examples use the last three frames (six frames ran out of GPU memory).
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
$FT/train_generic.sh Y1 "$HOME/data/robot/mix_Y1.json" --epochs 2 --init-adapter /data/vsr/adapters/ft_qat > /dev/null
./eval_robofac_variants.sh Y1 Y1 --variants tasklast3 2>&1 | grep "^tasklast3" | sed "s/^/Y1 /"
./eval_robot.sh Y1 robofac_ident3 native Y1 gemma-4-E2B-it-qat | cut -c1-300 | sed "s/^/Y1 ident3 /"
./eval_robot.sh X8id3 robofac_ident3 native X8 gemma-4-E2B-it-qat | cut -c1-300 | sed "s/^/X8 ident3 (not trained on it) /"
./eval_robot.sh baseid3 robofac_ident3 native | cut -c1-300 | sed "s/^/base ident3 /"
for s in sample1 sample2 sample3; do $FT/eval_hf.sh Y1_ret "$s" Y1 gemma-4-E2B-it-qat; done
./eval_robot.sh Y1 robospatial_configuration native Y1 | cut -c1-200
echo all done
