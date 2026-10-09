#!/usr/bin/env bash
# Error types learned from REAL videos (public RoboFAC real data, split by episode):
#   R60 train on 60% of the episodes, test on the other 40%      R25 the same with a quarter of those training episodes
#   "s" starts from the plain model, "d" from D1 (the adapter trained on simulation only): does the simulation help once real examples are added?
#   L_<task> leave-one-task-out: train on the other five tasks' real videos, test on the unseen task
cd "$(dirname "${BASH_SOURCE[0]}")"
FT=../finetune; R=~/data/robot/results
ev() {  # TAG FOLDER [ADAPTER]
  ./eval_robot.sh "$1" "$2" native "${3:-}" gemma-4-E2B-it-qat | cut -c1-100
  python3 analyse_ident.py "$R/$1_${2}_native.json"
}
train() {  # TAG MIX [extra args]
  local tag="$1" mix="$2"; shift 2
  $FT/train_generic.sh "$tag" "$HOME/data/robot/$mix" --epochs 2 --lr 2e-4 "$@" > /dev/null
}
echo "== references: no real training"
ev baseR40 robofac_ident_r40; ev D1r40 robofac_ident_r40 D1
echo "== R60 / R25"
train R60s mix_R60.json;                                        ev R60s robofac_ident_r40 R60s
train R60d mix_R60.json --init-adapter /data/vsr/adapters/D1;   ev R60d robofac_ident_r40 R60d
train R25s mix_R25.json --accum 8;                              ev R25s robofac_ident_r40 R25s
train R25d mix_R25.json --accum 8 --init-adapter /data/vsr/adapters/D1; ev R25d robofac_ident_r40 R25d
echo "== leave-one-task-out"
for t in InsertCylinder StackCube PullCubeByTool; do
  ev baseL_$t robofac_ident_loto_$t; ev D1L_$t robofac_ident_loto_$t D1
  train L_$t mix_L_$t.json;  ev L_$t robofac_ident_loto_$t L_$t
done
echo all done
