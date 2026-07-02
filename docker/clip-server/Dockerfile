# The stock `jinaai/clip-server` image does not bundle HuggingFace `transformers`.
# The multilingual open_clip checkpoints this stack uses by default
# (e.g. xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k) have an XLM-RoBERTa text
# tower that open_clip loads via `transformers` at model-load time. Without it the
# Jina Flow aborts on boot with:
#   RuntimeError: Please `pip install transformers` to use pre-trained HuggingFace models
# So we add a Python-3.8-compatible `transformers` on top of the stock image.
#
# English-only CLIP models (e.g. ViT-B-32::openai) do NOT need this, but installing
# transformers is harmless for them, so this image works for every supported model.
ARG CLIP_SERVER_BASE=jinaai/clip-server
FROM ${CLIP_SERVER_BASE}

# Pinned to a release that still supports the image's Python 3.8 and is contemporary
# with its open_clip. Override at build time with --build-arg TRANSFORMERS_VERSION=...
ARG TRANSFORMERS_VERSION=4.30.2
RUN pip install --no-cache-dir "transformers==${TRANSFORMERS_VERSION}"
