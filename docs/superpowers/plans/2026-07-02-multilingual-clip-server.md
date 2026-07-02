# Multilingual CLIP Embedding Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `jinaai/clip-server` with a custom FastAPI + `open_clip` embedding server that emulates the Jina `/post` protocol, fixing multilingual (Japanese) text→image relevance while keeping all changes inside `docker-multimodalsearch`.

**Architecture:** A small Python service loads the OpenCLIP XLM-RoBERTa model natively (so the multilingual text projection is applied correctly), exposes a Jina-compatible `POST /post` that returns `{"data":[{"embedding":[…]}]}` with L2-normalized float vectors, and a `GET /health`. The encoder is a separate module behind an `Encoder` protocol so the HTTP contract is unit-tested with a fake and the real model is integration-tested. The `fess-webapp-multimodal` plugin and the `mosaic` theme are unchanged.

**Tech Stack:** Python 3.11, FastAPI, uvicorn, `open_clip_torch`, `transformers` (modern, unpinned-to-4.30), `sentencepiece`, torch (CPU wheels), Pillow, pytest.

## Global Constraints

- Default model: `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k` (open_clip `arch::pretrained`), MIT-licensed.
- Default vector dimension: **512** (`MULTIMODAL_DIMENSION=512`); `space_type=cosinesimil` → embeddings **must be L2-normalized server-side**.
- Server listens on port **51000** internally; plugin default `clip.server.endpoint=http://clip_server:51000` is preserved.
- Response envelope exactly: `{"data":[{"embedding":[<floats>]}, …]}` — `embedding` is a **plain JSON array of numbers**, never a base64/NdArray object. One entry per input doc, in order. Success = HTTP 200 + `Content-Type: application/json`.
- Request accepted: `{"data":[{"text":"…"}|{"blob":"<base64>"}], "execEndpoint":"/"}`. `execEndpoint` and any extra doc fields are ignored.
- Fess `15.7.0-noble`, OpenSearch `3.7.0`, plugin `fess-webapp-multimodal:15.7.0` — unchanged.
- CPU-first default; `xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k` (dim 1024) is a documented opt-in only.
- No changes to `fess-webapp-multimodal` or `fess-themes`. No search-by-image.

## Wire Contract Reference (verified from CasClient)

Request (text): `POST /post`, `Content-Type: application/json`, body `{"data":[{"text":"running dogs"}],"execEndpoint":"/"}`.
Request (image): body `{"data":[{"blob":"<base64 of a 224x224 letterboxed PNG>"}],"execEndpoint":"/"}`.
Response (must return): `{"data":[{"embedding":[0.1,0.2,…]}]}` (512 floats, L2-normalized). Client reads `data[0].embedding`, converts each via `Number.floatValue()`, does **not** normalize. Client sets **no timeout and no retry**.

## File Structure

All new server code lives under `docker/clip-server/` (replacing the old Jina-based image).

- `docker/clip-server/app/__init__.py` — package marker.
- `docker/clip-server/app/config.py` — env parsing; `ServerConfig`, `parse_model_name`, `resolve_device`, `load_config`.
- `docker/clip-server/app/server.py` — FastAPI layer; `Encoder` protocol, `create_app(encoder)`, `build_encoder_from_env`, `create_production_app`.
- `docker/clip-server/app/encoder.py` — `OpenClipEncoder` (model load, encode_texts, encode_images, L2-normalize, dimension validation).
- `docker/clip-server/tests/test_config.py` — config unit tests.
- `docker/clip-server/tests/test_server.py` — HTTP contract unit tests (FakeEncoder).
- `docker/clip-server/tests/test_encoder.py` — integration tests (real model; `@pytest.mark.integration`).
- `docker/clip-server/tests/conftest.py` — registers the `integration` marker.
- `docker/clip-server/requirements.txt` — runtime deps.
- `docker/clip-server/requirements-dev.txt` — test deps.
- `docker/clip-server/Dockerfile` — replaces the Jina-based Dockerfile.
- `docker/clip-server/README.md` — how to run/test the server locally.

Modified (later tasks): `compose.yaml`, `.env`, `.env.example`, `bin/setup.sh`, `bin/init-fess-index.sh`, `README.md`. Removed: `config/clip.yaml`, `config/clip.yaml.template`.

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
Expected: FAIL with `ModuleNotFoundError: No module named 'app'` (or `app.config`).

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
Expected: PASS (3 passed). (Requires `pip install pytest`; full dev deps come in Task 5, but pytest alone suffices here.)

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
- Consumes: nothing from Task 1 yet (real wiring is Task 5).
- Produces: `Encoder` protocol with `encode_texts(list[str])->list[list[float]]`, `encode_images(list[bytes])->list[list[float]]`, `info` property (`dict`); `create_app(encoder: Encoder) -> FastAPI` exposing `POST /post` and `GET /health`.

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

Run: `cd docker/clip-server && python -m pytest tests/test_server.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.server'` (needs `pip install fastapi 'httpx' pillow`; if those are missing you'll instead see an import error for fastapi — install them first: `pip install fastapi httpx pillow`).

- [ ] **Step 3: Write minimal implementation**

`docker/clip-server/app/server.py`:
```python
import base64
import binascii
from typing import Protocol

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


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
                embedding = encoder.encode_texts([text])[0]
            elif blob is not None:
                try:
                    raw = base64.b64decode(blob, validate=True)
                except (binascii.Error, ValueError):
                    return JSONResponse(status_code=400, content={"error": "invalid base64 blob"})
                embedding = encoder.encode_images([raw])[0]
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

### Task 3: OpenCLIP encoder + dimension validation

**Files:**
- Create: `docker/clip-server/app/encoder.py`
- Create: `docker/clip-server/tests/conftest.py`
- Test: `docker/clip-server/tests/test_encoder.py`

**Interfaces:**
- Consumes: `ServerConfig` (Task 1); satisfies the `Encoder` protocol (Task 2).
- Produces: `OpenClipEncoder(config: ServerConfig)` with `encode_texts`, `encode_images`, `info`; raises `RuntimeError` on dimension mismatch at construction.

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

Run: `cd docker/clip-server && python -m pytest tests/test_encoder.py -v -m integration`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.encoder'` (or, once deps exist, collection error). Requires `pip install open_clip_torch transformers sentencepiece torch numpy pillow` — install if not present. First run downloads the model (~1.6 GB); allow time.

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

    def _validate_dimension(self) -> None:
        probe = self.encode_texts(["dimension probe"])[0]
        if len(probe) != self._config.dimension:
            raise RuntimeError(
                f"Model '{self._config.model_name}' produces {len(probe)}-dim embeddings "
                f"but MULTIMODAL_DIMENSION={self._config.dimension}. Set "
                f"MULTIMODAL_DIMENSION={len(probe)} and recreate the content_vector index."
            )

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
Expected: PASS (4 passed). The `test_multilingual_text_projection_differentiates` passing is the direct proof the serving bug is fixed.

- [ ] **Step 5: Commit**

```bash
git add docker/clip-server/app/encoder.py docker/clip-server/tests/conftest.py docker/clip-server/tests/test_encoder.py
git commit -m "feat(clip-server): add open_clip encoder with L2-norm and dimension check"
```

---

### Task 4: Production wiring, dependencies, Dockerfile, container smoke test

**Files:**
- Modify: `docker/clip-server/app/server.py` (add factory)
- Create: `docker/clip-server/requirements.txt`
- Create: `docker/clip-server/requirements-dev.txt`
- Create: `docker/clip-server/Dockerfile`
- Create: `docker/clip-server/README.md`

**Interfaces:**
- Consumes: `create_app` (Task 2), `load_config` (Task 1), `OpenClipEncoder` (Task 3).
- Produces: `build_encoder_from_env() -> Encoder`; `create_production_app() -> FastAPI` (uvicorn `--factory` target). Container listens on `51000`.

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

(No new unit test: importing `app.server` must stay light — the real encoder is built only when `create_production_app()` is called by uvicorn `--factory`, exercised by the container smoke test below. `tests/test_server.py` still imports `create_app` without loading a model.)

- [ ] **Step 2: Create dependency files**

`docker/clip-server/requirements.txt`:
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

# CPU-only torch (avoids pulling the multi-GB CUDA wheel). The cpu index hosts
# both x86_64 and aarch64 manylinux wheels for this version.
RUN pip install --no-cache-dir "torch==2.2.2" --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

EXPOSE 51000

CMD ["uvicorn", "app.server:create_production_app", "--factory", "--host", "0.0.0.0", "--port", "51000"]
```

- [ ] **Step 4: Create the server README**

`docker/clip-server/README.md`:
```markdown
# clip-server (custom open_clip embedding server)

Drop-in replacement for jinaai/clip-server. Emulates `POST /post`:
- Request: `{"data":[{"text":"..."}|{"blob":"<base64>"}],"execEndpoint":"/"}`
- Response: `{"data":[{"embedding":[<512 L2-normalized floats>]}]}`
- `GET /health` → `{"status":"ok","model":...,"dimension":...,"device":...}`

## Configuration (env)
- `CLIP_MODEL_NAME` (default `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k`)
- `MULTIMODAL_DIMENSION` (default `512`; must match the model's output dim)
- `CLIP_DEVICE` (`cpu` | `cuda` | `auto`)

## Test
    pip install -r requirements-dev.txt
    python -m pytest tests -v            # unit (fast)
    python -m pytest tests -v -m integration   # loads the real model (slow)
```

- [ ] **Step 5: Build the image and smoke-test the container**

```bash
cd docker/clip-server
docker build -t docker-multimodalsearch/clip-server:local .
docker run -d --name clip-smoke -p 51000:51000 -v "$PWD/.cache:/cache" docker-multimodalsearch/clip-server:local
# wait for the model to download + load on first boot
for i in $(seq 1 60); do curl -sf http://localhost:51000/health && break || sleep 10; done
curl -s http://localhost:51000/health
DIM=$(curl -s -XPOST http://localhost:51000/post -H 'Content-Type: application/json' \
  -d '{"data":[{"text":"山の夕日"}],"execEndpoint":"/"}' | python -c 'import sys,json;print(len(json.load(sys.stdin)["data"][0]["embedding"]))')
echo "embedding dim = $DIM"
docker rm -f clip-smoke
```
Expected: `/health` returns `{"status":"ok",...,"dimension":512,...}`; `embedding dim = 512`.

- [ ] **Step 6: Commit**

```bash
git add docker/clip-server/app/server.py docker/clip-server/requirements.txt docker/clip-server/requirements-dev.txt docker/clip-server/Dockerfile docker/clip-server/README.md
git commit -m "feat(clip-server): production factory, deps, Dockerfile, container smoke test"
```

---

### Task 5: Swap the compose service and env to the custom server

**Files:**
- Modify: `compose.yaml` (the `clip_server` service)
- Modify: `.env`, `.env.example`
- Modify: `bin/setup.sh` (drop clip.yaml rendering)
- Remove: `config/clip.yaml`, `config/clip.yaml.template`

**Interfaces:**
- Consumes: the image built in Task 4.
- Produces: a `clip_server` service reachable at `http://clip_server:51000/post` by `fess01`.

- [ ] **Step 1: Read the current files to get exact anchors**

Run: `sed -n '46,90p' compose.yaml` and `cat .env.example` and `sed -n '1,140p' bin/setup.sh`
Expected: see the current `clip_server` service (build context `docker/clip-server`, `platform: linux/amd64`, `command: ["/home/cas/clip_config.yaml"]`, the Python-socket healthcheck, the `./data/clip_server/cache` volume) and the clip.yaml render block in `setup.sh`.

- [ ] **Step 2: Rewrite the `clip_server` service in `compose.yaml`**

Replace the existing `clip_server:` service block with (adjust indentation/network name to match the file; keep the service name `clip_server`):
```yaml
  clip_server:
    build:
      context: ./docker/clip-server
    image: ${CLIP_SERVER_IMAGE:-docker-multimodalsearch/clip-server:local}
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
      retries: 20
      start_period: 300s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```
Notes: **removed** `platform: linux/amd64` (build native for the host arch → faster CPU inference on Apple Silicon), **removed** `command:` (uvicorn is the image CMD). The internal port 51000 is not published (unchanged). Leave `fess01`'s `depends_on: clip_server` as-is; the `/health` check now makes `service_healthy` meaningful if you choose to use it.

- [ ] **Step 3: Update `.env` and `.env.example`**

In both files: delete the `CLIP_SERVER_BASE=...` and `TRANSFORMERS_VERSION=...` lines. Keep `CLIP_MODEL_NAME`, `MULTIMODAL_DIMENSION`, `CLIP_MIN_SCORE`, `CLIP_SERVER_IMAGE`. Add under the model section:
```
# Embedding server device: cpu | cuda | auto
CLIP_DEVICE=cpu
```

- [ ] **Step 4: Remove clip.yaml and its rendering**

```bash
git rm config/clip.yaml config/clip.yaml.template
```
In `bin/setup.sh`, delete the block that renders `config/clip.yaml` from the template (the `sed`/`envsubst` substitution of `__CLIP_MODEL_NAME__`). Leave the rest of `setup.sh` (dirs, system.properties seeding, theme sync) intact.

- [ ] **Step 5: Validate compose config**

Run: `docker compose config >/dev/null && echo OK`
Expected: `OK` (no YAML/interpolation errors; no reference to the removed clip.yaml).

- [ ] **Step 6: Commit**

```bash
git add compose.yaml .env .env.example bin/setup.sh config/clip.yaml config/clip.yaml.template
git commit -m "feat: swap clip_server to the custom open_clip image; drop Jina clip.yaml"
```

---

### Task 6: Dimension-change detection in the reindex helper

**Files:**
- Modify: `bin/init-fess-index.sh`

**Interfaces:**
- Consumes: `MULTIMODAL_DIMENSION`, the OpenSearch endpoint the script already uses.
- Produces: a warning (and non-zero-ish guidance) when the live `content_vector` dimension differs from `MULTIMODAL_DIMENSION`.

- [ ] **Step 1: Read the current script**

Run: `cat bin/init-fess-index.sh`
Expected: see how it detects the endpoint/index and currently checks only that `content_vector` exists.

- [ ] **Step 2: Add a dimension check**

After the existing "field exists" check, add (adapt variable names/index resolution to the script's existing style; `${SEARCH_ENGINE_HTTP_URL}` and the resolved `${INDEX}` are already available in the script):
```bash
expected_dim="${MULTIMODAL_DIMENSION:-512}"
current_dim="$(curl -s "${SEARCH_ENGINE_HTTP_URL}/${INDEX}/_mapping" \
  | python3 -c 'import sys,json;m=json.load(sys.stdin);
props=next(iter(m.values()))["mappings"]["properties"];
print(props.get("content_vector",{}).get("dimension",""))' 2>/dev/null || true)"

if [ -n "${current_dim}" ] && [ "${current_dim}" != "${expected_dim}" ]; then
  log_warn "content_vector dimension mismatch: index=${current_dim} expected=${expected_dim}."
  log_warn "The model dimension changed. Recreate the index (drop content_vector and reindex) before crawling."
fi
```
(Use `log_warn` if the script sources `scripts/lib/common.sh`; otherwise `echo` to stderr.)

- [ ] **Step 3: Syntax-check the script**

Run: `bash -n bin/init-fess-index.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add bin/init-fess-index.sh
git commit -m "feat(init-fess-index): warn on content_vector dimension mismatch"
```

---

### Task 7: Update README and docs

**Files:**
- Modify: `README.md`

**Interfaces:** none (documentation).

- [ ] **Step 1: Read the sections to change**

Run: `grep -n -i "clip-server\|clip_server\|known limitation\|text-projection\|text-to-image\|transformers\|Model swap\|clip.yaml" README.md`
Expected: locate the architecture/CLIP-server section, the "Known limitations" note about the multilingual text-projection, and the "Model swap" section.

- [ ] **Step 2: Rewrite the CLIP-server / architecture description**

Replace the jinaai/clip-server description with the custom server: "A custom FastAPI + open_clip server (`docker/clip-server/`) loads the OpenCLIP XLM-RoBERTa model natively and serves `POST /post` (Jina-compatible) returning L2-normalized embeddings; the `fess-webapp-multimodal` plugin talks to it unchanged at `http://clip_server:51000`."

- [ ] **Step 3: Remove the fixed "known limitation"**

Delete the note stating multilingual text→image relevance is weak due to the clip-server text projection. Optionally add a one-line "Multilingual (incl. Japanese) text queries are supported" statement instead.

- [ ] **Step 4: Rewrite the "Model swap" section**

Document: to upgrade quality, set `CLIP_MODEL_NAME=xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k` and `MULTIMODAL_DIMENSION=1024` in `.env`, then `docker compose up -d --build clip_server`, and **reindex** (dimension change → recreate `content_vector`; `bin/init-fess-index.sh` warns on mismatch). Note H/14 is heavier (GPU recommended; set `CLIP_DEVICE=auto`).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: describe the custom clip-server and refreshed model-swap guidance"
```

---

### Task 8: End-to-end verification (docker compose + Claude in Chrome)

**Files:** none (verification only). Record results in the PR description / a short note.

- [ ] **Step 1: Bring up the stack**

```bash
./bin/setup.sh
docker compose up -d --build
docker compose ps
```
Expected: all services healthy; `clip_server` `/health` reports `dimension: 512`. First boot downloads the model into `./data/clip_server/cache` (allow several minutes).

- [ ] **Step 2: Seed content, index, crawl**

Run the repo's documented flow: `./bin/fetch-sample-images.sh`, ensure `init-fess-index` completed (reindex baked `content_vector`), then start the crawler job per README (Admin scheduler) and wait for docs + thumbnails.

- [ ] **Step 3: Verify Japanese relevance in the mosaic gallery via Claude in Chrome**

Load the browser tools (single ToolSearch: `tabs_context_mcp,navigate,computer,read_page,tabs_create_mcp`). Open `http://localhost:8080/`, run Japanese queries 「山の夕日」「猫」「花」 and English `mountain sunset`, `cat`. Confirm: relevant images appear in the thumbnail grid; results carry Visual/Blend badges; Japanese and the English equivalent return overlapping/relevant images. Capture a screenshot per query.

- [ ] **Step 4: Compare against the differentiation criterion**

Confirm the top results for 「山の夕日」 are genuinely sunset/landscape images (not arbitrary), demonstrating the fixed multilingual projection end-to-end. If relevance is still weak, STOP and debug the encoder (do not paper over it).

- [ ] **Step 5: Record outcome**

Note pass/fail per query (with screenshots) for the PR. No commit (verification only), unless a fix was needed.

---

## Self-Review

**1. Spec coverage:**
- Root-cause fix (native open_clip projection) → Task 3 (`test_multilingual_text_projection_differentiates`).
- Custom FastAPI server emulating `/post` → Tasks 2, 4.
- Jina wire-contract parity (`data[0].embedding` plain float array, L2-normalized) → Task 2 tests + Task 3 normalization + Global Constraints.
- CPU-first B/32 512-dim default → config defaults (Task 1), Dockerfile env, compose env.
- Startup dimension validation → Task 3 (`_validate_dimension`, `test_dimension_mismatch_raises`).
- Model-swap + reindex dimension handling → Task 6 (init-fess-index warning), Task 7 (docs).
- Remove Jina artifacts (clip.yaml, transformers pin, socket healthcheck) → Task 5.
- Model cache volume path change → Task 5 (`/cache`, `HF_HOME`).
- Theme unchanged → no task (explicit non-goal).
- E2E via docker compose + Claude in Chrome → Task 8.

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; every command has expected output. The one intentional "adapt to the script's existing style" (Task 6 Step 2) is bounded by a concrete snippet and a `bash -n` gate.

**3. Type consistency:** `Encoder` protocol (`encode_texts`, `encode_images`, `info`) is defined in Task 2 and implemented by `OpenClipEncoder` in Task 3 with identical signatures; `create_app` / `build_encoder_from_env` / `create_production_app` names are consistent across Tasks 2, 4, and the Dockerfile CMD; `ServerConfig` fields match between Task 1 definition and Task 3 usage.

**Gaps found & fixed:** added `protobuf` to `requirements.txt` (XLM-R tokenizer path needs it); made the production factory a uvicorn `--factory` target so unit tests never load the real model.
