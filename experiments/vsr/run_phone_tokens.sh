#!/usr/bin/env bash
# The phone processes a 640x480 frame as about 130 image tokens; training and the PC evaluation used about 266 (the HF processor enlarges a frame
# up to its 280-token budget). Does matching the phone to that raise the accuracy of X8? Success detection with the last frame / last three frames,
# and VSR, with the app's default and with -llamaImageMinTokens 266.
source "$(dirname "${BASH_SOURCE[0]}")/phone_lib.sh"
MODEL=gemma-4-e2b-qat-q4_0-it; ROBOT=~/data/robot/results; PROBE="$REPO/experiments/robot_eval/probe_robofac_phone.py"
stop_app() { pymobiledevice3 developer dvt pkill --bundle jp.localai.iphone-server >/dev/null 2>&1; sleep 3; }
stop_app; python3 "$VSR/phone_files.py" set-adapter $MODEL gemma-4-e2b-x8-lora-f16 | tail -1
echo "== default image tokens"
load_model $MODEL
python3 $PROBE $MODEL $ROBOT/phone_x8_default_tasklast1.json --variant tasklast1
echo "== image tokens 266-280 (matches training)"
load_model $MODEL "-llamaImageMinTokens 266 -llamaImageMaxTokens 280"
python3 $PROBE $MODEL $ROBOT/phone_x8_tok266_tasklast1.json --variant tasklast1
for s in sample1 sample2 sample3; do probe $MODEL x8tok266 $s; done
python3 "$VSR/analyse.py" $R/x8tok266_sample1.json $R/x8tok266_sample2.json $R/x8tok266_sample3.json | cut -c1-200
python3 $PROBE $MODEL $ROBOT/phone_x8_tok266_tasklast3.json --variant tasklast3
echo all done
