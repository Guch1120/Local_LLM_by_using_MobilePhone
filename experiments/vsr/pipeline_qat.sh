#!/usr/bin/env bash
# After training on the QAT base (adapter ft_qat): evaluate in bf16, merge, export to GGUF Q4_0 and as a LoRA adapter,
# then measure on the phone: the merged model, and the adapter applied at run time on the official QAT Q4_0.
source "$(dirname "${BASH_SOURCE[0]}")/phone_lib.sh"
F="$REPO/experiments/finetune/eval_hf.sh"; M=~/models; LLAMA="${LLAMA_CPP:-$HOME/tools/llama.cpp}"   # a llama.cpp checkout at tag b10456
DOCKER_USER=(--user "$(id -u):$(id -g)" -v /etc/passwd:/etc/passwd:ro -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1)
until grep -q "saved /data/vsr/adapters/ft_qat" "$D/ft_qat.log"; do sleep 30; done
if [ -z "${SKIP_EVAL:-}" ]; then
echo "== bf16 evaluation on the QAT base"
for S in sample1 sample2 sample3 seen shapes; do $F ftqat $S ft_qat gemma-4-E2B-it-qat; done
for S in sample1 sample2 sample3; do $F qatbase $S "" gemma-4-E2B-it-qat; done
fi
echo "== merge and export"
docker run --rm --gpus all "${DOCKER_USER[@]}" -v ~/models:/models -v ~/data:/data -v "$REPO/experiments/finetune":/work vlm-finetune:dev \
  python merge.py --model /models/hf/gemma-4-E2B-it-qat --adapter /data/vsr/adapters/ft_qat --out /models/hf/gemma-4-E2B-ftqat 2>&1 | tail -1
cp $M/hf/gemma-4-E2B-it-qat/tokenizer.json $M/hf/gemma-4-E2B-it-qat/tokenizer_config.json $M/hf/gemma-4-E2B-ftqat/
docker run --rm -v ~/models:/models -v ~/data:/data -v "$LLAMA":/llama vlm-finetune:dev bash -c "
  pip install -q gguf >/dev/null 2>&1
  python /llama/convert_hf_to_gguf.py /models/hf/gemma-4-E2B-ftqat --outfile /models/gemma-4-E2B-ftqat-f16.gguf --outtype f16 2>&1 | tail -1
  python /llama/convert_lora_to_gguf.py /data/vsr/adapters/ft_qat --base /models/hf/gemma-4-E2B-it-qat --outfile /models/gemma-4-E2B-ftqat-lora-f16.gguf --outtype f16 2>&1 | tail -1
  apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq cmake g++ make >/dev/null 2>&1
  cmake -S /llama -B /tmp/build -DGGML_CUDA=OFF -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1
  cmake --build /tmp/build --target llama-quantize -j8 >/dev/null 2>&1
  /tmp/build/bin/llama-quantize /models/gemma-4-E2B-ftqat-f16.gguf /models/gemma-4-E2B-ftqat-q4_0.gguf Q4_0 2>&1 | tail -2
  chown -R 1000:1000 /models /data/vsr/adapters /data/vsr/results"
ls -l $M/gemma-4-E2B-ftqat-*.gguf
echo "== waiting for the phone queue"
while pgrep -f night_phone.sh >/dev/null; do sleep 30; done
echo "== phone: QAT-trained adapter at run time on the official QAT Q4_0 (combination of both ideas)"
(cd "$REPO" && pymobiledevice3 developer dvt pkill --bundle jp.localai.iphone-server >/dev/null 2>&1; sleep 3)
python3 "$VSR/phone_files.py" remove gemma-4-e2b-ft1 | tail -2
python3 "$VSR/phone_files.py" remove ft1-lora | tail -1
python3 "$VSR/phone_files.py" upload $M/gemma-4-E2B-ftqat-lora-f16.gguf
load_model gemma-4-e2b-qat-q4_0-it "-llamaLoraPath gemma-4-E2B-ftqat-lora-f16.gguf"
for S in sample1 sample2 sample3; do probe gemma-4-e2b-qat-q4_0-it qatlora_off $S; done
probe gemma-4-e2b-qat-q4_0-it qatlora_on sample3 --think
echo "== phone: merged QAT-trained model requantized to Q4_0"
(cd "$REPO" && timeout 2400 bash scripts/iphone/push_model.sh $M/gemma-4-E2B-ftqat-q4_0.gguf $M/mmproj-gemma-4-E2B-qat-it.gguf 2>&1 | tr '\r' '\n' | grep "OK\|ERROR\|Errno" | tail -3)
load_model gemma-4-e2b-ftqat-q4_0
for S in sample1 sample2 sample3; do probe gemma-4-e2b-ftqat-q4_0 ftqatmerged_off $S; done
probe gemma-4-e2b-ftqat-q4_0 ftqatmerged_on sample3 --think
echo "== done"
