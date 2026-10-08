#!/usr/bin/env bash
# GPU queue: (Y1) VSR adapter + success detection + error types, then (Y2) how many last frames / which gaps from scratch.
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
# Y1: continue from the VSR adapter on success detection (task text + last three frames) and error-type questions (six frames)
$FT/train_generic.sh Y1 "$HOME/data/robot/mix_Y1.json" --epochs 2 --init-adapter /data/vsr/adapters/ft_qat > /dev/null
./eval_robofac_variants.sh Y1 Y1 --variants tasklast3 2>&1 | grep "^tasklast3" | sed "s/^/Y1 /"
./eval_robot.sh Y1 robofac_real native Y1 gemma-4-E2B-it-qat --types identification/above | cut -c1-400 | sed "s/^/Y1 ident /"
./eval_robot.sh X8id robofac_real native X8 gemma-4-E2B-it-qat --types identification/above | cut -c1-400 | sed "s/^/X8 ident (not trained on it) /"
for s in sample1 sample2 sample3; do $FT/eval_hf.sh Y1_ret "$s" Y1 gemma-4-E2B-it-qat; done
./eval_robot.sh Y1 robospatial_configuration native Y1 | cut -c1-200
# Y2: input variants, trained from scratch like X2 (task text + the chosen frames)
for v in last1 last2 last6 gap4; do
  $FT/train_generic.sh Y2_$v "$HOME/data/robot/mix_Y2_$v.json" --epochs 2 > /dev/null
  ./eval_robofac_variants.sh Y2_$v Y2_$v --variants task$v 2>&1 | grep "^task$v" | sed "s/^/Y2_$v /"
done
./eval_robofac_variants.sh qatbase2 "" --variants tasklast1,tasklast2,tasklast6,taskgap4 2>&1 | grep "^task" | sed "s/^/base /"
echo all done
