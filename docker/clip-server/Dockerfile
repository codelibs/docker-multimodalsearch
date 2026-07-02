FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/cache/huggingface \
    CLIP_MODEL_NAME=xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k \
    MULTIMODAL_DIMENSION=512 \
    CLIP_DEVICE=cpu \
    CLIP_SERVER_PORT=51000

WORKDIR /app

# CPU-only torch + torchvision. BuildKit populates TARGETARCH automatically.
#   amd64 : PyPI's default torch wheel is the multi-GB CUDA build, so pull the
#           CPU-only wheels from the pytorch cpu index.
#   arm64 : the pytorch cpu index has NO linux-aarch64 wheels, but PyPI's
#           default aarch64 torch/torchvision wheels are already CPU-only.
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "amd64" ]; then \
        pip install --no-cache-dir "torch==2.2.2" "torchvision==0.17.2" \
            --index-url https://download.pytorch.org/whl/cpu ; \
    else \
        pip install --no-cache-dir "torch==2.2.2" "torchvision==0.17.2" ; \
    fi

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

EXPOSE 51000

CMD ["uvicorn", "app.server:create_production_app", "--factory", "--host", "0.0.0.0", "--port", "51000"]
