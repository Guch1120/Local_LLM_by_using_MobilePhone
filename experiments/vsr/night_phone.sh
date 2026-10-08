#!/usr/bin/env bash
# Phone queue: wait for the running LoRA evaluation, then thinking off/on on the untouched sample3.
source "$(dirname "${BASH_SOURCE[0]}")/phone_lib.sh"
while pgrep -f "probe.py" >/dev/null; do sleep 20; done
echo "== QAT base, sample3: thinking off, then on"
load_model gemma-4-e2b-qat-q4_0-it
probe gemma-4-e2b-qat-q4_0-it qat_off sample3
probe gemma-4-e2b-qat-q4_0-it qat_on sample3 --think
echo "== runtime LoRA (ft1) on QAT Q4_0, sample3: thinking on"
load_model gemma-4-e2b-qat-q4_0-it "-llamaLoraPath gemma-4-E2B-ft1-lora-f16.gguf"
probe gemma-4-e2b-qat-q4_0-it loraqat_on sample3 --think
echo "== done"
