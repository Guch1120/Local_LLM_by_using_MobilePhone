#!/usr/bin/env bash
# Third round: keep the VSR skill while learning success detection (input: task text + last three frames).
#   X7 X2's data plus 3000 VSR examples, trained together from scratch
#   X8 start from the VSR adapter (ft_qat) and train on X2's data afterwards
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune
run() {
  local tag="$1" mix="$2" variant="$3"; shift 3
  $FT/train_generic.sh "$tag" "$HOME/data/robot/$mix" --epochs 2 "$@" > /dev/null
  ./eval_robofac_variants.sh "$tag" "$tag" --variants "$variant" 2>&1 | grep "^$variant" | sed "s/^/$tag /"
  for s in sample1 sample2 sample3; do $FT/eval_hf.sh "${tag}_ret" "$s" "$tag" gemma-4-E2B-it-qat; done
  ./eval_robot.sh "${tag}" robospatial_configuration native "$tag" 2>/dev/null | cut -c1-200
  ./eval_robot.sh "${tag}" robospatial_configuration json "$tag" 2>/dev/null | cut -c1-200
}
run X7 mix_X7.json tasklast3
run X8 mix_X2.json tasklast3 --init-adapter /data/vsr/adapters/ft_qat
echo all done
