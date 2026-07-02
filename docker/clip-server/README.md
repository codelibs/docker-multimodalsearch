# clip-server (custom open_clip embedding server)

Drop-in replacement for jinaai/clip-server. Emulates `POST /post`:
- Request: `{"data":[{"text":"..."}|{"blob":"<base64>"}],"execEndpoint":"/"}`
- Response: `{"data":[{"embedding":[<512 L2-normalized floats>]}]}`
- `GET /health` -> `{"status":"ok","model":...,"dimension":...,"device":...}`

## Configuration (env)
- `CLIP_MODEL_NAME` (default `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k`)
- `MULTIMODAL_DIMENSION` (default `512`; must match the model's output dim)
- `CLIP_DEVICE` (`cpu` | `cuda` | `auto`)

First boot downloads the model (~1.6 GB) into `HF_HOME` (bind-mounted to
`./data/clip_server/cache`); it requires network access at runtime, not build time.

## Test
    pip install -r requirements-dev.txt
    python -m pytest tests -v                    # unit (fast)
    python -m pytest tests -v -m integration     # loads the real model (slow)
