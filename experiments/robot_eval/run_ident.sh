#!/usr/bin/env bash
# Failure-type (error-type) questions: does more simulation data help, and does it interfere with success detection?
#   Y3a VSR adapter + success detection + ALL 1,569 error-type examples (six frames)      Y3c error-type examples only, from the plain QAT model
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
$FT/train_generic.sh Y3a "$HOME/data/robot/mix_Y3a.json" --epochs 1 --init-adapter /data/vsr/adapters/ft_qat > /dev/null
./eval_robot.sh Y3a robofac_real native Y3a gemma-4-E2B-it-qat --types identification/above | cut -c1-300 | sed "s/^/Y3a ident (six frames) /"
./eval_robofac_variants.sh Y3a Y3a --variants tasklast3 2>&1 | grep "^tasklast3" | sed "s/^/Y3a /"
$FT/train_generic.sh Y3c "$HOME/data/robot/mix_Y3c.json" --epochs 1 > /dev/null
./eval_robot.sh Y3c robofac_real native Y3c gemma-4-E2B-it-qat --types identification/above | cut -c1-300 | sed "s/^/Y3c ident (six frames) /"
echo all done
