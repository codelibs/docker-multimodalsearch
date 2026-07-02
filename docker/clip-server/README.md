# clip-server (custom open_clip embedding server)

Drop-in replacement for jinaai/clip-server. Emulates `POST /post`:
- Request: `{"data":[{"text":"..."}|{"blob":"<base64>"}],"execEndpoint":"/"}`
- Response: `{"data":[{"embedding":[<512 L2-normalized floats>]}]}`
- `GET /health` -> `{"status":"ok","model":...,"dimension":...,"device":...}`
- Errors: a `blob` that is not valid base64, or not a decodable / too-large image,
  returns HTTP 400 (`{"error":...}`).

## Configuration (env)
- `CLIP_MODEL_NAME` (default `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k`)
- `MULTIMODAL_DIMENSION` (default `512`; must match the model's output dim)
- `CLIP_DEVICE` (`cpu` | `cuda` | `auto`)
- `CLIP_MAX_IMAGE_PIXELS` (default `64000000`; Pillow decode cap for untrusted
  images — oversized / decompression-bomb inputs are rejected with HTTP 400)

First boot downloads the model (~1.6 GB) into `HF_HOME` (bind-mounted to
`./data/clip_server/cache`); it requires network access at runtime, not build time.

## Runtime security
- Runs as a non-root user (`clip`, default uid/gid `1000`, configurable at build
  time via `--build-arg APP_UID=`/`APP_GID=`). The image never runs as root,
  because it decodes untrusted crawled image bytes with Pillow.
- The bind-mounted model cache (`./data/clip_server/cache`) must be writable by
  that uid. Set `CLIP_UID`/`CLIP_GID` in the environment (compose) to match the
  host user that owns the cache directory if the defaults do not.
- Pinned `pillow==12.3.0` and `transformers==4.48.0` to pick up image-decoder and
  deserialization CVE fixes.
- Untrusted image bytes are decoded defensively: malformed/truncated or oversized
  (decompression-bomb) blobs raise a decode error that `POST /post` returns as an
  HTTP 400 instead of a 500, bounded by `CLIP_MAX_IMAGE_PIXELS`.
- `HOME` points at the writable cache mount so `~/.cache` fallbacks work even when
  the container runs as a non-1000 UID with no `/etc/passwd` home.

## Test
    pip install -r requirements-dev.txt
    python -m pytest tests -v                    # unit (fast)
    python -m pytest tests -v -m integration     # loads the real model (slow)
