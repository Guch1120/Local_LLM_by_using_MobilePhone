#!/usr/bin/env bash
# Second round: separate the two changes of X2 (frames, task text) and mix VSR into X2.
#   X4 six frames + task text     X5 last three frames without task text     X6 X2 plus VSR examples
cd "$(dirname "${BASH_SOURCE[0]}")"
while pgrep -f "[r]un_experiments.sh" >/dev/null; do sleep 20; done
FT=../finetune
run() {
  local tag="$1" mix="$2" variant="$3"; shift 3
  $FT/train_generic.sh "$tag" "$HOME/data/robot/$mix" --epochs 2 "$@" > /dev/null
  ./eval_robofac_variants.sh "$tag" "$tag" --variants "$variant" 2>&1 | grep "^$variant" | sed "s/^/$tag /"
  for s in sample1 sample2 sample3; do $FT/eval_hf.sh "${tag}_ret" "$s" "$tag" gemma-4-E2B-it-qat; done
  ./eval_robot.sh "${tag}" robospatial_configuration native "$tag" 2>/dev/null | cut -c1-200
}
run X4 mix_X4.json task6
run X5 mix_X5.json last3
run X6 mix_X6.json tasklast3
echo all done
