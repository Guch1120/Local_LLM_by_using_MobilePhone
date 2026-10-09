#!/usr/bin/env bash
# Diagnosis: can the error type be learned at all? Z1's loss stayed at the chance level.
# D1: Z1's data minus 300 held-out videos, trained longer (2 epochs) with a higher learning rate (2e-4); tested on the held-out SIMULATION videos and on the real ones.
cd "$(dirname "${BASH_SOURCE[0]}")"
while pgrep -f "[r]un_ident2.sh|[r]un_rightfront.sh" >/dev/null; do sleep 30; done
FT=../finetune
$FT/train_generic.sh D1 "$HOME/data/robot/mix_Z1d.json" --epochs 2 --lr 2e-4 > /dev/null
./eval_robot.sh D1sim robofac_sim_ident_eval native D1 gemma-4-E2B-it-qat | cut -c1-120
python3 analyse_sim_ident.py ~/data/robot/results/D1sim_robofac_sim_ident_eval_native.json
./eval_robot.sh D1 robofac_real native D1 gemma-4-E2B-it-qat --types identification/above | cut -c1-120
python3 analyse_ident.py ~/data/robot/results/D1_robofac_real_native.json
./eval_robot.sh baseSim robofac_sim_ident_eval native "" gemma-4-E2B-it-qat | cut -c1-120
python3 analyse_sim_ident.py ~/data/robot/results/baseSim_robofac_sim_ident_eval_native.json
echo all done
