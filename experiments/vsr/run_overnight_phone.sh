#!/usr/bin/env bash
# Phone queue: the X8 adapter (VSR first, then RoboFAC success detection) as a run-time LoRA on the official QAT Q4_0, against the same model without it.
source "$(dirname "${BASH_SOURCE[0]}")/phone_lib.sh"
MODEL=gemma-4-e2b-qat-q4_0-it; ROBOT=~/data/robot/results; mkdir -p $ROBOT
stop_app() { pymobiledevice3 developer dvt pkill --bundle jp.localai.iphone-server >/dev/null 2>&1; sleep 3; }
echo "== convert the X8 adapter"
docker run --rm -v ~/models:/models -v ~/data:/data -v "${LLAMA_CPP:-$HOME/tools/llama.cpp}":/llama vlm-finetune:dev bash -c "
  pip install -q gguf >/dev/null 2>&1
  python /llama/convert_lora_to_gguf.py /data/vsr/adapters/X8 --base /models/hf/gemma-4-E2B-it-qat --outfile /models/gemma-4-E2B-X8-lora-f16.gguf --outtype f16 2>&1 | tail -1
  chown 1000:1000 /models/gemma-4-E2B-X8-lora-f16.gguf"
ls -l ~/models/gemma-4-E2B-X8-lora-f16.gguf
echo "== without an adapter"
stop_app; python3 "$VSR/phone_files.py" set-adapter $MODEL none | tail -1
load_model $MODEL
curl -s -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/capabilities | python3 -c "import sys,json;print('adapter:',json.load(sys.stdin).get('adapter'))"
python3 "$REPO/experiments/robot_eval/probe_robofac_phone.py" $MODEL $ROBOT/phone_base_tasklast3.json
echo "== with the X8 adapter"
stop_app; (cd "$REPO" && timeout 900 bash scripts/iphone/push_model.sh ~/models/gemma-4-E2B-X8-lora-f16.gguf 2>&1 | tr '\r' '\n' | grep "OK\|ERROR\|Errno" | tail -3)
for i in $(seq 1 40); do python3 "$VSR/phone_files.py" list 2>/dev/null | grep -q "adapter-gemma-4-e2b-x8" && break; sleep 5; done
stop_app; python3 "$VSR/phone_files.py" set-adapter $MODEL gemma-4-e2b-x8-lora-f16 | tail -1
load_model $MODEL
curl -s -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/capabilities | python3 -c "import sys,json;print('adapter:',json.load(sys.stdin).get('adapter'))"
python3 "$REPO/experiments/robot_eval/probe_robofac_phone.py" $MODEL $ROBOT/phone_x8_tasklast3.json
for s in sample1 sample2 sample3; do probe $MODEL x8phone $s; done
python3 "$VSR/analyse.py" $R/x8phone_sample1.json $R/x8phone_sample2.json $R/x8phone_sample3.json | cut -c1-200
echo all done
