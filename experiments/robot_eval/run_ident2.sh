#!/usr/bin/env bash
# Error types again, without the mismatch of the first attempt: classes drawn evenly (200 per class), options shown in random order
# and as random subsets of three (the real test shows three options), six frames.
#   Z1 error types only, from the plain QAT model        Z2 VSR adapter + success detection + the same error-type examples
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
$FT/train_generic.sh Z1 "$HOME/data/robot/mix_Z1.json" --epochs 1 > /dev/null
./eval_robot.sh Z1 robofac_real native Z1 gemma-4-E2B-it-qat --types identification/above | cut -c1-200 | sed "s/^/Z1 /"
python3 analyse_ident.py ~/data/robot/results/Z1_robofac_real_native.json
$FT/train_generic.sh Z2 "$HOME/data/robot/mix_Z2.json" --epochs 1 --init-adapter /data/vsr/adapters/ft_qat > /dev/null
./eval_robot.sh Z2 robofac_real native Z2 gemma-4-E2B-it-qat --types identification/above | cut -c1-200 | sed "s/^/Z2 /"
python3 analyse_ident.py ~/data/robot/results/Z2_robofac_real_native.json
./eval_robofac_variants.sh Z2 Z2 --variants tasklast3 2>&1 | grep "^tasklast3" | sed "s/^/Z2 /"
for s in sample1 sample2 sample3; do $FT/eval_hf.sh Z2_ret "$s" Z2 gemma-4-E2B-it-qat; done
./eval_robot.sh Z2 robospatial_configuration native Z2 | cut -c1-200
echo all done
