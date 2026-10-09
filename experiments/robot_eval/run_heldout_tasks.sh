#!/usr/bin/env bash
# Held-out task families: train without some simulation tasks, then look at the same tasks on real videos (per-task AUC is computed afterwards).
#   H1 without PickCube, StackCube, PushCube    H2 without PullCube, PullCubeTool     (X2's recipe otherwise; InsertCylinder has no simulation counterpart)
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
for h in H1 H2; do
  $FT/train_generic.sh $h "$HOME/data/robot/mix_$h.json" --epochs 2 > /dev/null
  ./eval_robofac_variants.sh $h $h --variants tasklast3 2>&1 | grep "^tasklast3" | sed "s/^/$h /"
done
echo all done
