# Fine-tuning environment for Gemma 4 E2B (QLoRA). RTX 5060 Ti (Blackwell, sm_120) needs CUDA 12.8 wheels.
# build: docker build -t vlm-finetune:dev experiments/finetune
# run:   docker run --rm --gpus all -v ~/models:/models -v ~/data:/data \
#          -v $PWD/experiments/finetune:/work vlm-finetune:dev python train_lora.py ...
FROM python:3.12-slim
RUN pip install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cu128
RUN pip install --no-cache-dir "transformers>=5.10.1" "peft>=0.19.0" trl accelerate bitsandbytes datasets pillow sentencepiece protobuf
WORKDIR /work
