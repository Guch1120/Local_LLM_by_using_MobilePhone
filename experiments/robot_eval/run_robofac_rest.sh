#!/usr/bin/env bash
# After the running base-model evaluation finishes: the same evaluation with the fine-tuned adapter.
cd "$(dirname "${BASH_SOURCE[0]}")"
while pgrep -f "eval_robot_hf.py" >/dev/null; do sleep 20; done
./eval_robot.sh ftqat robofac_real native ft_qat
echo done
