# syntax=docker/dockerfile:1
FROM python:3.11-slim

# UID/GID for the non-root runtime user. Override at build time (and match the
# runtime `user:` in compose) so the bind-mounted model cache stays writable.
ARG APP_UID=1000
ARG APP_GID=1000

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/cache/huggingface \
    CLIP_MODEL_NAME=xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k \
    MULTIMODAL_DIMENSION=512 \
    CLIP_DEVICE=cpu \
    CLIP_SERVER_PORT=51000

# Run as a dedicated non-root user: this service decodes untrusted crawled image
# bytes with Pillow, so a decoder memory-safety bug must not execute as root.
RUN groupadd --gid "${APP_GID}" clip \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" --no-log-init --create-home --shell /usr/sbin/nologin clip

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

# HF_HOME cache mount point owned by the runtime user so the first-boot model
# download can write to the bind-mounted ./data/clip_server/cache.
RUN mkdir -p /cache/huggingface \
    && chown -R clip:clip /app /cache

EXPOSE 51000

USER clip

CMD ["uvicorn", "app.server:create_production_app", "--factory", "--host", "0.0.0.0", "--port", "51000"]
