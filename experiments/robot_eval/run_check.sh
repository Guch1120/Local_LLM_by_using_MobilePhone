#!/usr/bin/env bash
# Sanity check of train_generic.py: VSR alone through the generic pipeline (the first adapter, ft_qat, reached AUC 0.838 with train_lora.py).
cd "$(dirname "${BASH_SOURCE[0]}")"
while pgrep -f "[r]un_experiments3.sh" >/dev/null; do sleep 20; done
FT=../finetune
$FT/train_generic.sh V0 "$HOME/data/robot/mix_vsr.json" --epochs 1 > /dev/null
for s in sample1 sample2 sample3; do $FT/eval_hf.sh "V0_ret" "$s" V0 gemma-4-E2B-it-qat; done
echo all done
