#!/usr/bin/env bash
# Can the error type be read when the model sees the motion in between? Twelve frames instead of six, at several image-token budgets
# (video input in Gemma 4 uses 70 tokens per frame). Zero-shot, the plain QAT model; balanced accuracy over the three classes.
cd "$(dirname "${BASH_SOURCE[0]}")"
for n in 70 140 280; do
  ./eval_robot.sh dense12_t$n robofac_ident12 native "" gemma-4-E2B-it-qat --types identification12/above --max-soft-tokens $n | cut -c1-90
  python3 analyse_ident.py ~/data/robot/results/dense12_t${n}_robofac_ident12_native.json
done
echo all done
