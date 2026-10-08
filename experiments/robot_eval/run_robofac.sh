#!/usr/bin/env bash
cd "$(dirname "${BASH_SOURCE[0]}")"
./eval_robot.sh qat robofac_real native
./eval_robot.sh ftqat robofac_real native ft_qat
./eval_robot.sh ftqat robofac_real json ft_qat
./eval_robot.sh qat robofac_real json
echo done
