# Multilingual CLIP Embedding Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `jinaai/clip-server` with a custom FastAPI + `open_clip` embedding server that emulates the Jina `/post` protocol, fixing multilingual (Japanese) text→image relevance while keeping all changes inside `docker-multimodalsearch`.

**Architecture:** A small Python service loads the OpenCLIP XLM-RoBERTa model natively (so the multilingual text projection is applied correctly), exposes a Jina-compatible `POST /post` returning `{"data":[{"embedding":[…]}]}` with L2-normalized float vectors, and a `GET /health`. The encoder is a separate module behind an `Encoder` protocol so the HTTP contract is unit-tested with a fake and the real model is integration-tested. The `fess-webapp-multimodal` plugin and the `mosaic` theme are unchanged.

**Tech Stack:** Python 3.11, FastAPI, uvicorn, `open_clip_torch`, `transformers` (modern), `sentencepiece`, torch + torchvision (CPU), Pillow, pytest.

## Global Constraints

- Default model: `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k` (open_clip `arch::pretrained`), MIT-licensed.
- Default vector dimension: **512** (`MULTIMODAL_DIMENSION=512`); `space_type=cosinesimil` → embeddings **must be L2-normalized server-side**.
- Server listens on port **51000** internally; plugin default `clip.server.endpoint=http://clip_server:51000` is preserved.
- Response envelope exactly: `{"data":[{"embedding":[<floats>]}, …]}` — `embedding` is a **plain JSON array of numbers**, never a base64/NdArray object. One entry per input doc, in order. Success = HTTP 200 + `Content-Type: application/json`.
- Request accepted: `{"data":[{"text":"…"}|{"blob":"<base64>"}], "execEndpoint":"/"}`. `execEndpoint` and any extra doc fields are ignored.
- Fess `15.7.0-noble`, OpenSearch `3.7.0`, plugin `fess-webapp-multimodal:15.7.0` — unchanged.
- CPU-first default; `xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k` (dim 1024) is a documented opt-in only.
- No changes to `fess-webapp-multimodal` or `fess-themes`. No search-by-image.
- **Upgrade rule:** switching the server/model re-embeds the space. On a fresh install nothing extra is needed, but upgrading an existing stack (even same 512-dim) requires deleting crawled docs and **re-crawling** — a Fess reindex only copies docs, it does not recompute vectors.

## Wire Contract Reference (verified from CasClient)

Request (text): `POST /post`, `Content-Type: application/json`, body `{"data":[{"text":"running dogs"}],"execEndpoint":"/"}`.
Request (image): body `{"data":[{"blob":"<base64 of a 224x224 letterboxed PNG>"}],"execEndpoint":"/"}` (Java `Base64.getEncoder()` standard alphabet, no line breaks, `=` padded).
Response (must return): `{"data":[{"embedding":[0.1,0.2,…]}]}` (512 floats, L2-normalized). Client reads `data[0].embedding`, converts each via `Number.floatValue()`, does **not** normalize. Client sets **no timeout and no retry** (respond promptly; on failure the doc simply fails to embed).

## Repo facts the tasks depend on (verified)

- `compose.yaml`: network `multimodal_net`; current `clip_server` block ~lines 46–87 has `container_name: clip_server`, `restart: always`, `platform: linux/amd64`, `command: ["/home/cas/clip_config.yaml"]`, a python-socket healthcheck, volume `./data/clip_server/cache`. `fess01 → clip_server` is `condition: service_started`. The one-shot `init-fess-index` service is `alpine:3.21`, `entrypoint: ["sh","/init-fess-index.sh"]`, env only `FESS_URL, SEARCH_ENGINE_HTTP_URL, FESS_ADMIN_PASSWORD, MAX_WAIT`.
- `.gitignore` ignores `/.env` and `/config/clip.yaml`. So `.env` and `config/clip.yaml` are **untracked**; only `.env.example` and `config/clip.yaml.template` are tracked.
- `bin/setup.sh` renders `config/clip.yaml` from the template via `sed s#__CLIP_MODEL_NAME__#...#`; it also reads/defaults `CLIP_MODEL_NAME`; it logs with plain `echo` (no `scripts/lib/common.sh`).
- `bin/init-fess-index.sh` is `#!/bin/sh`, `set -eu`, `apk add --no-cache curl jq` (no python3, no yq). Index alias var is `${DOC_ALIAS}` (default `fess.search`). Logging helper is `log()`. It has a `doc_has_vector()` check and an early `exit 0` when the vector field already exists.
- `docker/clip-server/` currently holds only the Jina-based `Dockerfile`.

## File Structure

All new server code lives under `docker/clip-server/` (replacing the old Jina-based image).

- `docker/clip-server/app/__init__.py`, `app/config.py`, `app/server.py`, `app/encoder.py`
- `docker/clip-server/tests/conftest.py`, `tests/test_config.py`, `tests/test_server.py`, `tests/test_encoder.py`
- `docker/clip-server/requirements.txt`, `requirements-dev.txt`, `Dockerfile`, `.dockerignore`, `README.md`

Modified (later tasks): `compose.yaml`, `.env`, `.env.example`, `.gitignore`, `bin/setup.sh`, `bin/init-fess-index.sh`, `README.md`. Removed: `config/clip.yaml.template` (tracked) + `config/clip.yaml` (untracked).

---

### Task 1: Server config module

**Files:**
- Create: `docker/clip-server/app/__init__.py`
- Create: `docker/clip-server/app/config.py`
- Test: `docker/clip-server/tests/test_config.py`

**Interfaces:**
- Produces: `ServerConfig(model_name:str, arch:str, pretrained:str|None, dimension:int, device:str, port:int)`; `parse_model_name(str)->tuple[str,str|None]`; `resolve_device(str)->str`; `load_config()->ServerConfig`.

- [ ] **Step 1: Write the failing test**

`docker/clip-server/tests/test_config.py`:
```python
from app.config import load_config, parse_model_name


def test_parse_model_name_with_pretrained():
    assert parse_model_name("xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k") == (
        "xlm-roberta-base-ViT-B-32",
        "laion5b-s13b-b90k",
    )


def test_parse_model_name_without_pretrained():
    assert parse_model_name("ViT-B-32") == ("ViT-B-32", None)


def test_load_config_defaults(monkeypatch):
    monkeypatch.delenv("CLIP_MODEL_NAME", raising=False)
    monkeypatch.setenv("CLIP_DEVICE", "cpu")
    monkeypatch.setenv("MULTIMODAL_DIMENSION", "512")
    cfg = load_config()
    assert cfg.arch == "xlm-roberta-base-ViT-B-32"
    assert cfg.pretrained == "laion5b-s13b-b90k"
    assert cfg.dimension == 512
    assert cfg.device == "cpu"
    assert cfg.port == 51000
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd docker/clip-server && python -m pytest tests/test_config.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app'`.

- [ ] **Step 3: Write minimal implementation**

`docker/clip-server/app/__init__.py`: (empty file)

`docker/clip-server/app/config.py`:
```python
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class ServerConfig:
    model_name: str
    arch: str
    pretrained: str | None
    dimension: int
    device: str
    port: int


def parse_model_name(model_name: str) -> tuple[str, str | None]:
    """Split an open_clip 'arch::pretrained' name into (arch, pretrained)."""
    if "::" in model_name:
        arch, pretrained = model_name.split("::", 1)
        return arch, pretrained
    return model_name, None


def resolve_device(preference: str) -> str:
    """Resolve 'auto' to cuda when available; otherwise return the preference."""
    if preference == "auto":
        import torch

        return "cuda" if torch.cuda.is_available() else "cpu"
    return preference


def load_config() -> ServerConfig:
    model_name = os.environ.get(
        "CLIP_MODEL_NAME", "xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k"
    )
    arch, pretrained = parse_model_name(model_name)
    return ServerConfig(
        model_name=model_name,
        arch=arch,
        pretrained=pretrained,
        dimension=int(os.environ.get("MULTIMODAL_DIMENSION", "512")),
        device=resolve_device(os.environ.get("CLIP_DEVICE", "cpu")),
        port=int(os.environ.get("CLIP_SERVER_PORT", "51000")),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd docker/clip-server && python -m pytest tests/test_config.py -v`
Expected: PASS (3 passed). (Needs only `pip install pytest`.)

- [ ] **Step 5: Commit**

```bash
git add docker/clip-server/app/__init__.py docker/clip-server/app/config.py docker/clip-server/tests/test_config.py
git commit -m "feat(clip-server): add config module for model/device/dimension env"
```

---

### Task 2: FastAPI `/post` + `/health` contract (fake encoder)

**Files:**
- Create: `docker/clip-server/app/server.py`
- Test: `docker/clip-server/tests/test_server.py`

**Interfaces:**
- Produces: `Encoder` protocol with `encode_texts(list[str])->list[list[float]]`, `encode_images(list[bytes])->list[list[float]]`, `info` property (`dict`); `create_app(encoder: Encoder) -> FastAPI` exposing `POST /post` and `GET /health`. The `/post` handler offloads the (synchronous) encode to a threadpool so the event loop stays free for `/health`.

- [ ] **Step 1: Write the failing test**

`docker/clip-server/tests/test_server.py`:
```python
import base64
import io

from fastapi.testclient import TestClient
from PIL import Image

from app.server import create_app


class FakeEncoder:
    def __init__(self):
        self.text_calls = []
        self.image_calls = []

    def encode_texts(self, texts):
        self.text_calls.append(texts)
        return [[float(len(t)), 0.1, 0.2] for t in texts]

    def encode_images(self, images):
        self.image_calls.append(images)
        return [[0.9, 0.8, 0.7] for _ in images]

    @property
    def info(self):
        return {"model": "fake", "dimension": 3, "device": "cpu"}


def _png_b64():
    buf = io.BytesIO()
    Image.new("RGB", (4, 4), (255, 0, 0)).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def test_post_text_returns_embedding_envelope():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{"text": "running dogs"}], "execEndpoint": "/"})
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("application/json")
    body = resp.json()
    assert list(body.keys()) == ["data"]
    assert body["data"][0]["embedding"] == [11.0, 0.1, 0.2]  # len("running dogs") == 11


def test_post_blob_decodes_image_and_returns_embedding():
    enc = FakeEncoder()
    client = TestClient(create_app(enc))
    resp = client.post("/post", json={"data": [{"blob": _png_b64()}], "execEndpoint": "/"})
    assert resp.status_code == 200
    assert resp.json()["data"][0]["embedding"] == [0.9, 0.8, 0.7]
    assert len(enc.image_calls[0][0]) > 0  # server passed decoded raw bytes


def test_post_preserves_order_for_batch():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{"text": "a"}, {"text": "bb"}]})
    embs = [d["embedding"][0] for d in resp.json()["data"]]
    assert embs == [1.0, 2.0]


def test_post_missing_text_and_blob_is_400():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{}]})
    assert resp.status_code == 400


def test_post_invalid_base64_is_400():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{"blob": "!!!not-base64!!!"}]})
    assert resp.status_code == 400


def test_health_reports_ok_and_info():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["dimension"] == 3
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd docker/clip-server && pip install fastapi httpx pillow && python -m pytest tests/test_server.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.server'`.

- [ ] **Step 3: Write minimal implementation**

`docker/clip-server/app/server.py`:
```python
import base64
import binascii
from typing import Protocol

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool


class Encoder(Protocol):
    def encode_texts(self, texts: list[str]) -> list[list[float]]: ...

    def encode_images(self, images: list[bytes]) -> list[list[float]]: ...

    @property
    def info(self) -> dict: ...


def create_app(encoder: Encoder) -> FastAPI:
    app = FastAPI()

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok", **encoder.info}

    @app.post("/post")
    async def post(request: Request):
        payload = await request.json()
        docs = payload.get("data") or []
        results: list[dict] = []
        for doc in docs:
            text = doc.get("text")
            blob = doc.get("blob")
            if text is not None:
                embedding = (await run_in_threadpool(encoder.encode_texts, [text]))[0]
            elif blob is not None:
                try:
                    raw = base64.b64decode(blob, validate=True)
                except (binascii.Error, ValueError):
                    return JSONResponse(status_code=400, content={"error": "invalid base64 blob"})
                embedding = (await run_in_threadpool(encoder.encode_images, [raw]))[0]
            else:
                return JSONResponse(
                    status_code=400, content={"error": "each data item needs 'text' or 'blob'"}
                )
            results.append({"embedding": embedding})
        return JSONResponse(content={"data": results})

    return app
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd docker/clip-server && python -m pytest tests/test_server.py -v`
Expected: PASS (6 passed).

- [ ] **Step 5: Commit**

```bash
git add docker/clip-server/app/server.py docker/clip-server/tests/test_server.py
git commit -m "feat(clip-server): add Jina-compatible /post and /health HTTP layer"
```

---

### Task 3: OpenCLIP encoder + dimension validation + warmup

**Files:**
- Create: `docker/clip-server/app/encoder.py`
- Create: `docker/clip-server/tests/conftest.py`
- Test: `docker/clip-server/tests/test_encoder.py`

**Interfaces:**
- Consumes: `ServerConfig` (Task 1); satisfies the `Encoder` protocol (Task 2).
- Produces: `OpenClipEncoder(config: ServerConfig)` with `encode_texts`, `encode_images`, `info`; validates output dimension and warms both towers at construction; raises `RuntimeError` on dimension mismatch.

- [ ] **Step 1: Write the failing test**

`docker/clip-server/tests/conftest.py`:
```python
def pytest_configure(config):
    config.addinivalue_line("markers", "integration: loads the real CLIP model (slow, downloads weights)")
```

`docker/clip-server/tests/test_encoder.py`:
```python
import io

import numpy as np
import pytest
from PIL import Image

from app.config import ServerConfig
from app.encoder import OpenClipEncoder


def _cfg(dimension: int) -> ServerConfig:
    return ServerConfig(
        model_name="xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k",
        arch="xlm-roberta-base-ViT-B-32",
        pretrained="laion5b-s13b-b90k",
        dimension=dimension,
        device="cpu",
        port=51000,
    )


def _cos(a, b):
    a, b = np.asarray(a), np.asarray(b)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


@pytest.fixture(scope="module")
def encoder():
    return OpenClipEncoder(_cfg(512))


@pytest.mark.integration
def test_text_embedding_is_512_and_normalized(encoder):
    emb = encoder.encode_texts(["a mountain sunset"])[0]
    assert len(emb) == 512
    assert abs(np.linalg.norm(emb) - 1.0) < 1e-3


@pytest.mark.integration
def test_image_embedding_is_512(encoder):
    buf = io.BytesIO()
    Image.new("RGB", (224, 224), (10, 20, 30)).save(buf, format="PNG")
    emb = encoder.encode_images([buf.getvalue()])[0]
    assert len(emb) == 512


@pytest.mark.integration
def test_multilingual_text_projection_differentiates(encoder):
    # Regression test for the fixed bug: multilingual text embeddings must be
    # well-differentiated. Japanese "mountain sunset" must be closer to the
    # English "mountain sunset" than to "a cat".
    ja_sunset, en_sunset, cat = encoder.encode_texts(
        ["山の夕日", "a mountain sunset at dusk", "a photo of a cat"]
    )
    assert _cos(ja_sunset, en_sunset) > _cos(ja_sunset, cat)


@pytest.mark.integration
def test_dimension_mismatch_raises(encoder):
    with pytest.raises(RuntimeError):
        OpenClipEncoder(_cfg(999))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd docker/clip-server && pip install open_clip_torch==2.24.0 transformers==4.38.2 sentencepiece==0.2.0 torch==2.2.2 torchvision==0.17.2 numpy==1.26.4 pillow && python -m pytest tests/test_encoder.py -v -m integration`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.encoder'`. First run downloads the model (~1.6 GB); allow time.

- [ ] **Step 3: Write minimal implementation**

`docker/clip-server/app/encoder.py`:
```python
import io

import numpy as np
import open_clip
import torch
from PIL import Image

from app.config import ServerConfig


class OpenClipEncoder:
    def __init__(self, config: ServerConfig) -> None:
        self._config = config
        self._device = torch.device(config.device)
        model, _, preprocess = open_clip.create_model_and_transforms(
            config.arch, pretrained=config.pretrained
        )
        model.eval()
        model.to(self._device)
        self._model = model
        self._preprocess = preprocess
        self._tokenizer = open_clip.get_tokenizer(config.arch)
        self._validate_dimension()
        self._warmup()

    def _validate_dimension(self) -> None:
        probe = self.encode_texts(["dimension probe"])[0]
        if len(probe) != self._config.dimension:
            raise RuntimeError(
                f"Model '{self._config.model_name}' produces {len(probe)}-dim embeddings "
                f"but MULTIMODAL_DIMENSION={self._config.dimension}. Set "
                f"MULTIMODAL_DIMENSION={len(probe)}, recreate the content_vector index, and re-crawl."
            )

    def _warmup(self) -> None:
        buffer = io.BytesIO()
        Image.new("RGB", (224, 224), (0, 0, 0)).save(buffer, format="PNG")
        self.encode_images([buffer.getvalue()])

    @property
    def info(self) -> dict:
        return {
            "model": self._config.model_name,
            "dimension": self._config.dimension,
            "device": self._config.device,
        }

    def encode_texts(self, texts: list[str]) -> list[list[float]]:
        tokens = self._tokenizer(texts).to(self._device)
        with torch.no_grad():
            features = self._model.encode_text(tokens)
            features = features / features.norm(dim=-1, keepdim=True)
        return features.cpu().numpy().astype(np.float32).tolist()

    def encode_images(self, images: list[bytes]) -> list[list[float]]:
        tensors = [
            self._preprocess(Image.open(io.BytesIO(raw)).convert("RGB")) for raw in images
        ]
        batch = torch.stack(tensors).to(self._device)
        with torch.no_grad():
            features = self._model.encode_image(batch)
            features = features / features.norm(dim=-1, keepdim=True)
        return features.cpu().numpy().astype(np.float32).tolist()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd docker/clip-server && python -m pytest tests/test_encoder.py -v -m integration`
Expected: PASS (4 passed). `test_multilingual_text_projection_differentiates` passing is the direct proof the serving bug is fixed.

- [ ] **Step 5: Commit**

```bash
git add docker/clip-server/app/encoder.py docker/clip-server/tests/conftest.py docker/clip-server/tests/test_encoder.py
git commit -m "feat(clip-server): add open_clip encoder with L2-norm, dim check, warmup"
```

---

### Task 4: Production wiring, dependencies, Dockerfile, container smoke test

**Files:**
- Modify: `docker/clip-server/app/server.py` (add factory)
- Create: `docker/clip-server/requirements.txt`, `requirements-dev.txt`
- Create: `docker/clip-server/Dockerfile`, `.dockerignore`
- Create: `docker/clip-server/README.md`
- Modify: `.gitignore` (ignore the smoke-test cache)

**Interfaces:**
- Consumes: `create_app` (Task 2), `load_config` (Task 1), `OpenClipEncoder` (Task 3).
- Produces: `build_encoder_from_env() -> Encoder`; `create_production_app() -> FastAPI` (uvicorn `--factory` target). Container listens on `51000`; the port binds only after the model loads, so ordering is gated by the compose healthcheck in Task 5.

- [ ] **Step 1: Add the production factory to `app/server.py`**

Append to `docker/clip-server/app/server.py`:
```python
def build_encoder_from_env() -> Encoder:
    from app.config import load_config
    from app.encoder import OpenClipEncoder

    return OpenClipEncoder(load_config())


def create_production_app() -> FastAPI:
    return create_app(build_encoder_from_env())
```
(Unit tests import `create_app` only and never load a model; the real encoder is built only when uvicorn calls `create_production_app()` via `--factory`, exercised by the smoke test below.)

- [ ] **Step 2: Create dependency files**

`docker/clip-server/requirements.txt` (torch/torchvision are installed separately in the Dockerfile to control the CPU wheel source — do not list them here):
```
open_clip_torch==2.24.0
transformers==4.38.2
sentencepiece==0.2.0
protobuf==4.25.3
pillow==10.2.0
fastapi==0.110.0
uvicorn[standard]==0.29.0
numpy==1.26.4
```

`docker/clip-server/requirements-dev.txt`:
```
-r requirements.txt
pytest==8.1.1
httpx==0.27.0
```

- [ ] **Step 3: Create the Dockerfile**

`docker/clip-server/Dockerfile`:
```dockerfile
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
```

- [ ] **Step 4: Create `.dockerignore` and update `.gitignore`**

`docker/clip-server/.dockerignore`:
```
.cache/
__pycache__/
*.pyc
.pytest_cache/
tests/
requirements-dev.txt
README.md
```

Append to the repo-root `.gitignore`:
```
/docker/clip-server/.cache/
```

- [ ] **Step 5: Create the server README**

`docker/clip-server/README.md`:
```markdown
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
```

- [ ] **Step 6: Build the image and smoke-test the container**

(Uses a throwaway named volume for the cache so the ~1.6 GB weights never land in the build context or the repo.)
```bash
cd docker/clip-server
docker build -t docker-multimodalsearch/clip-server:local .
docker run -d --name clip-smoke -p 51000:51000 -v clip-smoke-cache:/cache docker-multimodalsearch/clip-server:local
for i in $(seq 1 60); do curl -sf http://localhost:51000/health && break || sleep 10; done
curl -s http://localhost:51000/health
DIM=$(curl -s -XPOST http://localhost:51000/post -H 'Content-Type: application/json' \
  -d '{"data":[{"text":"山の夕日"}],"execEndpoint":"/"}' | python -c 'import sys,json;print(len(json.load(sys.stdin)["data"][0]["embedding"]))')
echo "embedding dim = $DIM"
docker rm -f clip-smoke && docker volume rm clip-smoke-cache
```
Expected: `/health` returns `{"status":"ok",...,"dimension":512,...}`; `embedding dim = 512`.

- [ ] **Step 7: Commit**

```bash
git add docker/clip-server/app/server.py docker/clip-server/requirements.txt docker/clip-server/requirements-dev.txt docker/clip-server/Dockerfile docker/clip-server/.dockerignore docker/clip-server/README.md .gitignore
git commit -m "feat(clip-server): production factory, deps, Dockerfile, smoke test"
```

---

### Task 5: Swap the compose service and env to the custom server

**Files:**
- Modify: `compose.yaml` (the `clip_server` service, `fess01.depends_on`, `init-fess-index.environment`)
- Modify: `.env`, `.env.example`
- Modify: `bin/setup.sh` (drop clip.yaml rendering + dead CLIP_MODEL_NAME reads)
- Remove: `config/clip.yaml.template` (tracked) and `config/clip.yaml` (untracked)

**Interfaces:**
- Consumes: the image built in Task 4.
- Produces: a `clip_server` service reachable at `http://clip_server:51000/post`, gated healthy before `fess01` starts.

- [ ] **Step 1: Read the current files to get exact anchors**

Run: `sed -n '46,90p' compose.yaml; sed -n '110,195p' compose.yaml; cat .env.example; sed -n '1,140p' bin/setup.sh`
Expected: see the current `clip_server` block, the `fess01 depends_on clip_server: condition: service_started`, the `init-fess-index` service env list, the clip.yaml render block + `CLIP_MODEL_NAME` reads in `setup.sh`, and the `# --- CLIP server image ... ---` comment block in `.env.example`.

- [ ] **Step 2: Rewrite the `clip_server` service in `compose.yaml`**

Replace the existing `clip_server:` block with (keep the service name and 2-space indentation to match the file):
```yaml
  clip_server:
    build:
      context: ./docker/clip-server
    image: ${CLIP_SERVER_IMAGE:-docker-multimodalsearch/clip-server:local}
    container_name: clip_server
    restart: always
    environment:
      CLIP_MODEL_NAME: ${CLIP_MODEL_NAME:-xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k}
      MULTIMODAL_DIMENSION: ${MULTIMODAL_DIMENSION:-512}
      CLIP_DEVICE: ${CLIP_DEVICE:-cpu}
      HF_HOME: /cache/huggingface
    volumes:
      - ./data/clip_server/cache:/cache
    networks:
      - multimodal_net
    healthcheck:
      test:
        - CMD
        - python
        - -c
        - "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:51000/health').status==200 else 1)"
      interval: 15s
      timeout: 10s
      retries: 40
      start_period: 600s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```
Notes: kept `container_name` and `restart: always`; **removed** `platform: linux/amd64` (native host arch → faster CPU inference on Apple Silicon) and `command:` (uvicorn is the image CMD). `start_period: 600s` + `retries: 40` cover the first-boot model download (the port binds only after load, so the healthcheck sees connection-refused until then — that's expected during `start_period`).

- [ ] **Step 3: Gate `fess01` on a healthy clip_server**

In `compose.yaml`, change the `fess01` dependency on `clip_server` from `condition: service_started` to `condition: service_healthy`, and update any adjacent comment that justified `service_started`:
```yaml
    depends_on:
      clip_server:
        condition: service_healthy
```
(Leave `fess01`'s other `depends_on` entries as they are.)

- [ ] **Step 4: Pass the dimension into the reindex one-shot**

In the `init-fess-index` service `environment:` block, add:
```yaml
      MULTIMODAL_DIMENSION: ${MULTIMODAL_DIMENSION:-512}
```
(so the dimension check added in Task 6 can compare against the configured value.)

- [ ] **Step 5: Update `.env` and `.env.example`**

`.env` is gitignored (edit it for your local run) and `.env.example` is tracked. In BOTH: delete the `# --- CLIP server image (built from ./docker/clip-server) ---` comment block that describes the stock Jina image plus the `CLIP_SERVER_BASE=...` and `TRANSFORMERS_VERSION=...` lines. Keep `CLIP_MODEL_NAME`, `MULTIMODAL_DIMENSION`, `CLIP_MIN_SCORE`, `CLIP_SERVER_IMAGE`. Under the model section add:
```
# Embedding server device: cpu | cuda | auto
CLIP_DEVICE=cpu
```

- [ ] **Step 6: Remove clip.yaml and its rendering + dead reads**

```bash
git rm config/clip.yaml.template
rm -f config/clip.yaml
```
In `bin/setup.sh`: delete the block that renders `config/clip.yaml` from the template (the `sed "s#__CLIP_MODEL_NAME__#...#"` line and its surrounding echo/comment), and delete the now-unused `CLIP_MODEL_NAME` read/default lines and the stale "render the live clip.yaml" header/inline comments. Leave the dirs, `system.properties` seeding, and theme sync intact.

- [ ] **Step 7: Validate compose config**

Run: `docker compose config >/dev/null && echo OK`
Expected: `OK` (no YAML/interpolation errors; no reference to the removed clip.yaml).

- [ ] **Step 8: Commit**

```bash
git add compose.yaml .env.example bin/setup.sh
git commit -m "feat: swap clip_server to the custom open_clip image; drop Jina clip.yaml"
```
(`config/clip.yaml.template` deletion is already staged by `git rm`; `.env` and the untracked `config/clip.yaml` are not committed.)

---

### Task 6: Dimension-change detection in the reindex helper

**Files:**
- Modify: `bin/init-fess-index.sh`

**Interfaces:**
- Consumes: `MULTIMODAL_DIMENSION` (now passed via compose, Task 5 Step 4), `${SEARCH_ENGINE_HTTP_URL}`, `${DOC_ALIAS}`, and the `log()` helper already in the script. Tools available in the Alpine container: `curl`, `jq`.
- Produces: a warning (and re-crawl reminder) when the live `content_vector` dimension differs from `MULTIMODAL_DIMENSION`.

- [ ] **Step 1: Read the script and confirm the mapping path**

Run: `cat bin/init-fess-index.sh`
Then, against a running stack (or note for the executor), confirm the JSON path of the vector dimension:
Run: `curl -s "${SEARCH_ENGINE_HTTP_URL}/${DOC_ALIAS}/_mapping" | jq '.[].mappings.properties.content_vector'`
Expected: an object containing `"dimension": 512` (adjust the jq path in Step 2 if the field nests differently, e.g. under `method`/`type`).

- [ ] **Step 2: Add the dimension check inside the existing "vector exists" branch**

The script early-`exit 0`s when `doc_has_vector` is true, so the check MUST go **inside** that `if ... then` branch, before the `exit 0`. Add:
```sh
    expected_dim="${MULTIMODAL_DIMENSION:-512}"
    current_dim="$(curl -s "${SEARCH_ENGINE_HTTP_URL}/${DOC_ALIAS}/_mapping" \
        | jq -r 'first(.[].mappings.properties.content_vector.dimension) // empty')"
    if [ -n "${current_dim}" ] && [ "${current_dim}" != "${expected_dim}" ]; then
        log "WARN: content_vector dimension mismatch: index=${current_dim} expected=${expected_dim}."
        log "WARN: The model/dimension changed. Recreate the index and re-crawl (re-embed);"
        log "WARN: a Fess reindex only copies documents and does NOT recompute embeddings."
    fi
```
(Use the script's `log` helper and `${DOC_ALIAS}`; do NOT use `python3`/`log_warn` — neither exists here.)

- [ ] **Step 3: Syntax-check the script**

Run: `sh -n bin/init-fess-index.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add bin/init-fess-index.sh
git commit -m "feat(init-fess-index): warn on content_vector dimension mismatch and re-crawl need"
```

---

### Task 7: Update README and docs

**Files:**
- Modify: `README.md`

**Interfaces:** none (documentation).

- [ ] **Step 1: Read the sections to change**

Run: `grep -n -i "clip-server\|clip_server\|known limitation\|text-projection\|text-to-image\|transformers\|Model swap\|clip.yaml\|reindex\|min_score" README.md`
Expected: locate the architecture/CLIP-server section, the "Known limitations" text-projection note, the "Model swap" section, and any reindex wording.

- [ ] **Step 2: Rewrite the CLIP-server / architecture description**

Replace the jinaai/clip-server description with: "A custom FastAPI + open_clip server (`docker/clip-server/`) loads the OpenCLIP XLM-RoBERTa model natively and serves `POST /post` (Jina-compatible) returning L2-normalized embeddings; the `fess-webapp-multimodal` plugin talks to it unchanged at `http://clip_server:51000`. The model is MIT-licensed. First boot downloads ~1.6 GB into `./data/clip_server/cache` and requires network access at runtime."

- [ ] **Step 3: Remove the fixed "known limitation"**

Delete the note that multilingual text→image relevance is weak due to the clip-server text projection. Add instead a one-line: "Multilingual text queries (including Japanese) are supported."

- [ ] **Step 4: Rewrite the "Model swap" section and add an upgrade note**

Document:
- To upgrade quality: set `CLIP_MODEL_NAME=xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k` and `MULTIMODAL_DIMENSION=1024` in `.env`, then `docker compose up -d --build clip_server`. Because the dimension changes (512→1024), recreate the index and **re-crawl** (a plain reindex fails copying 512-dim vectors into a 1024-dim field). H/14 is heavier — GPU recommended; set `CLIP_DEVICE=auto`.
- Add an **"Upgrading an existing deployment"** subsection: "Any server or model change re-embeds the vector space — even keeping the same 512 dimension. Vectors already indexed by the previous server are inconsistent with new query vectors. After upgrading, delete the crawled documents and **re-crawl** to re-embed the content; a Fess reindex only copies documents and does not recompute embeddings. Re-check `CLIP_MIN_SCORE`, whose ideal cutoff shifts with the model. Clearing the old `./data/clip_server/cache` bytes is safe (the new server uses a different cache layout)."

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: describe the custom clip-server, re-crawl-on-upgrade, model-swap guidance"
```

---

### Task 8: End-to-end verification (docker compose + Claude in Chrome)

**Files:** none (verification only). Record results in the PR description / a short note.

- [ ] **Step 1: Bring up the stack (fresh)**

```bash
./bin/setup.sh
docker compose up -d --build
docker compose ps
```
Expected: all services healthy; `clip_server` becomes `healthy` after the first-boot model download (allow several minutes; `fess01` waits for it via `service_healthy`). Confirm: `curl -s http://localhost:51000/health` → `dimension: 512` (from inside the network, or temporarily publish the port).

- [ ] **Step 2: Seed content, index, crawl**

Run the repo's documented flow: `./bin/fetch-sample-images.sh`, ensure `init-fess-index` completed (baked `content_vector`), then start the crawler job per README (Admin scheduler) and wait for docs + thumbnails.

- [ ] **Step 3: Verify Japanese relevance in the mosaic gallery via Claude in Chrome**

Load the browser tools (single ToolSearch: `tabs_context_mcp,navigate,computer,read_page,tabs_create_mcp`). Open `http://localhost:8080/`, run Japanese queries 「山の夕日」「猫」「花」 and English `mountain sunset`, `cat`. Confirm: relevant images appear in the thumbnail grid; results carry Visual/Blend badges; Japanese and the English equivalent return overlapping/relevant images. Capture a screenshot per query.

- [ ] **Step 4: Compare against the differentiation criterion**

Confirm the top results for 「山の夕日」 are genuinely sunset/landscape images, demonstrating the fixed multilingual projection end-to-end. If relevance is still weak, STOP and debug the encoder (do not paper over it).

- [ ] **Step 5: Record outcome**

Note pass/fail per query (with screenshots) for the PR. No commit (verification only) unless a fix was needed.

---

## Self-Review

**1. Spec coverage:**
- Root-cause fix (native open_clip projection) → Task 3 (`test_multilingual_text_projection_differentiates`).
- Custom FastAPI server emulating `/post` (plain float array, L2-normalized) → Tasks 2, 3, 4; Global Constraints.
- CPU-first B/32 512-dim default → Task 1 defaults, Dockerfile env, compose env.
- Startup dimension validation → Task 3 (`_validate_dimension`, `test_dimension_mismatch_raises`); warmup of both towers → Task 3 (`_warmup`).
- Re-crawl-on-upgrade + H/14 dimension handling → spec §9, Task 6 warning, Task 7 docs.
- Remove Jina artifacts (clip.yaml template, transformers pin, socket healthcheck) → Task 5.
- Model cache path change (`/cache`, `HF_HOME`) → Task 4 Dockerfile + Task 5 compose.
- Theme unchanged → non-goal, no task.
- E2E via docker compose + Claude in Chrome → Task 8.

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. The one "adjust the jq path if it nests differently" (Task 6 Step 1) is gated by a concrete live-dump check and a `sh -n` syntax gate.

**3. Type consistency:** `Encoder` protocol (`encode_texts`, `encode_images`, `info`) defined in Task 2, implemented identically by `OpenClipEncoder` in Task 3; `create_app` / `build_encoder_from_env` / `create_production_app` names consistent across Tasks 2, 4 and the Dockerfile CMD; `ServerConfig` fields consistent between Task 1 and Task 3.

**Review-driven corrections folded in (from the two adversarial review passes):**
- **P0** arm64 torch: Dockerfile now installs torch **and** `torchvision==0.17.2` arch-conditionally via `TARGETARCH` (cpu index only on amd64), fixing the false "aarch64 on cpu index" assumption.
- **P0** `git rm config/clip.yaml` would fail (untracked) → now `git rm config/clip.yaml.template` + `rm -f config/clip.yaml`; `.env` dropped from commits (gitignored).
- **P0** init-fess-index runs in python-less Alpine → check reimplemented in `jq`, using `${DOC_ALIAS}` and `log`, placed inside the `doc_has_vector` branch before `exit 0`; `MULTIMODAL_DIMENSION` now passed to that container (Task 5 Step 4).
- **P0/P1** re-crawl (not reindex) on upgrade; H/14 512→1024 reindex would fail → spec §9 + Task 7.
- **P1** unpinned `torchvision` → pinned and co-installed from the CPU index.
- **P1** startup ordering → `fess01` gated on `service_healthy`; `start_period` raised to 600s.
- **P1** build-context bloat → `.dockerignore` added; smoke test uses a throwaway named volume; `.gitignore` covers the cache.
- **P2** event-loop blocking → `/post` offloads encode via `run_in_threadpool`.
- **P1** kept `container_name`/`restart: always`; removed stale `.env`/`setup.sh` comments and dead `CLIP_MODEL_NAME` reads.
- Confirmed non-issues (left as-is): base64 `validate=True` (safe for Java `Base64.getEncoder()` output), L2-norm (ranking-neutral under cosinesimil), 224² double-resize (geometric no-op).
