#!/usr/bin/env bash
# Plan A: only the two failure types that every task has (grasping error, position deviation; chance 50%), each of the six tasks held out in turn.
# Class names as answers, language LoRA, 140 image tokens per frame. The linear probes and the zero-shot model are the references.
cd "$(dirname "${BASH_SOURCE[0]}")"
while pgrep -f "[r]un_loto_fixed.sh" >/dev/null; do sleep 30; done
FT=../finetune; R=~/data/robot/results
ev() { ./eval_robot.sh "$1" "$2" native "${3:-}" gemma-4-E2B-it-qat --max-soft-tokens 140 | cut -c1-70; python3 analyse_classify.py "$R/$1_${2}_native.json"; }
for t in StackCube PushCube PickCubeInBox PullCube InsertCylinder PullCubeByTool; do
  $FT/train_generic.sh B_$t "$HOME/data/robot/mix_bin_$t.json" --epochs 3 --lr 1e-4 --max-soft-tokens 140 > /dev/null
  ev B_$t robofac_cls_bin_$t B_$t
done
echo all done
