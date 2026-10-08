#!/usr/bin/env bash
# One factor at a time on success detection (real RoboFAC videos, camera "above"):
#   X1 RoboFAC detection data, six frames          X2 same data, task text + last three frames
#   X3 X1 plus VSR examples (does mixing keep the spatial skill?)
# Each run: train, success-detection AUC with the same input, then retention checks (VSR samples 1-3, RoboSpatial-Home).
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
run() {  # TAG MIX VARIANT [extra train args]
  local tag="$1" mix="$2" variant="$3"; shift 3
  $FT/train_generic.sh "$tag" "$HOME/data/robot/$mix" --epochs 2 "$@" > /dev/null
  ./eval_robofac_variants.sh "$tag" "$tag" --variants "$variant" 2>&1 | grep "^$variant" | sed "s/^/$tag /"
  for s in sample1 sample2 sample3; do $FT/eval_hf.sh "${tag}_ret" "$s" "$tag" gemma-4-E2B-it-qat; done
  ./eval_robot.sh "${tag}" robospatial_configuration native "$tag" 2>/dev/null | cut -c1-200
}
run X1 mix_X1.json even6
run X2 mix_X2.json tasklast3
run X3 mix_X3.json even6
echo all done
