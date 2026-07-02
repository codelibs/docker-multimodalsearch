# Multilingual Multimodal Search — Embedding Server Upgrade

- **Date:** 2026-07-02
- **Repo:** `docker-multimodalsearch`
- **Status:** Approved design (pre-implementation)
- **Related:** `codelibs/docker-multimodalsearch#2`, `codelibs/fess-themes#25`

## 1. Problem statement

`docker-multimodalsearch` provides a text→image multimodal search demo: Fess + OpenSearch
kNN over a `content_vector` field, with a `clip_server` service turning crawled images
(ingest time) and text queries (query time) into embeddings. The `fess-webapp-multimodal`
plugin owns both paths and speaks to the embedding server over HTTP.

The stack already runs a **multilingual** OpenCLIP model
(`xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k`, 512-dim, MIT). However, Japanese (and
generally non-English) text→image relevance is poor.

**Root cause (confirmed):** the poor relevance is a *serving* bug, not a model-quality
problem. `jinaai/clip-server` does not correctly apply the XLM-RoBERTa text projection, so
text embeddings come out poorly differentiated. PR #2's own "known limitations" note already
documents this. The model is fine; the server mis-serves its text tower.

**Evidence from model research:** the LAION XLM-R CLIP family is the right choice for this
use case — MIT-licensed (clean commercial use), a single jointly-trained image/text space
(required for kNN), CPU-capable at B/32, and empirically strong at Japanese (Recruit's own
benchmark shows it matching or beating Japanese-dedicated CLIP models). Alternatives were
rejected: `jina-clip-v2` and NLLB-SigLIP are CC-BY-NC (non-commercial self-host);
`stabilityai/japanese-stable-clip` has a restrictive license. SigLIP2 (Apache) is a viable
fallback only if English becomes co-primary; LINE `clip-japanese-base` (Apache) only if
Japanese-only. None of these beat "keep the model, fix the server" for this deployment.

## 2. Goals

- Fix multilingual (especially Japanese) text→image relevance.
- Keep the solution maintainable, commercially licensed, and CPU-runnable by default.
- Continue PR #2's modernization direction (Fess 15.7 / OpenSearch 3.7 / env-driven).
- **Contain all changes inside `docker-multimodalsearch`** — no changes to the
  `fess-webapp-multimodal` plugin or the `mosaic` theme.

## 3. Non-goals

- **Search-by-image** (image query → vector → kNN). Confirmed never supported (old docker
  `main` had no such UI; the plugin's query path is text-only — `getImageEmbedding` is
  ingest-only). Fess has no image-query interface. Out of scope.
- Changing the model family. The default stays OpenCLIP XLM-R (multilingual, MIT).
- Modifying the `fess-webapp-multimodal` plugin or `mosaic` theme source.
- Making H/14 (1024-dim) the default. It is documented as an opt-in GPU upgrade only.

## 4. Key decisions (agreed)

1. **Serving strategy:** replace `jinaai/clip-server` with a small custom **FastAPI +
   `open_clip`** embedding server that **emulates the Jina clip-server `/post` protocol**, so
   the plugin's `CasClient` works unchanged and all changes stay in this repo.
2. **Default model / hardware:** CPU-first — keep `xlm-roberta-base-ViT-B-32` (512-dim), so
   the default path needs no reindex and stays laptop-runnable. Document
   `xlm-roberta-large-ViT-H-14` (1024-dim) as an opt-in higher-quality upgrade.
3. **Search modes:** text-to-image only.

## 5. Architecture

Replace the `clip_server` service (currently `jinaai/clip-server`) with a custom image built
from `docker/clip-server/`.

| Aspect | Design |
|---|---|
| Implementation | Python + FastAPI + `open_clip_torch` + torch (CPU wheels) + Pillow + uvicorn |
| Model | Default `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k` (512-dim), loaded **natively via `open_clip`** so the XLM-R text projection is applied correctly |
| Protocol | Emulates Jina `POST /post`: accepts `{"data":[{"blob":"<b64>"}|{"text":"..."}],"execEndpoint":"/"}`, returns the envelope shape `CasClient` parses, with a per-doc `embedding` of floats |
| Normalization | L2-normalize embeddings (cosine kNN, `space_type=cosinesimil`) |
| Device | Default CPU; auto-detect and use CUDA when available (`CLIP_DEVICE=cpu\|cuda\|auto`) |
| Config | Model name, dimension, device, batch size, image size, log level via env |

Unchanged services: `search01` (OpenSearch), `content` (nginx crawl corpus), `fess01`
(Fess + plugin + `mosaic` theme), `init-fess-index`. The embedding server keeps listening on
port `51000` internally so the plugin default `clip.server.endpoint=http://clip_server:51000`
still applies.

### Data flow (unchanged shape, corrected server)

1. Crawl `http://content/` → plugin `CasExtractor` embeds each image via `POST /post`
   (`blob`) → stores L2-normalized vector on `content_vector`.
2. Text query → plugin `MultiModalQueryBuilder` embeds via `POST /post` (`text`) → OpenSearch
   kNN over `content_vector`, hybrid-fused with BM25 `default` searcher.
3. `mosaic` theme renders the thumbnail gallery and Keyword/Visual/Blend badges from the
   `searcher` field (Fess feature; unchanged).

## 6. The compatibility contract (highest risk)

The "drop-in" claim depends entirely on reproducing the exact JSON request/response envelope
that `CasClient` constructs and parses.

**Implementation gate — must be done first:**
1. Read `CasClient` in `fess-webapp-multimodal` precisely: the request body it POSTs for both
   `blob` (image) and `text`, **and** how it parses the response — the exact field path to
   the embedding (`data[].embedding`), and the encoding of that embedding (a plain JSON float
   array vs a DocArray NdArray object with `{buffer, shape, dtype}`).
2. Capture a real `jinaai/clip-server` `/post` response for a known input (text and image) as
   a golden fixture.
3. Build a **contract test**: assert the custom server's response for the same input matches
   the shape `CasClient` requires (field names, nesting, embedding encoding, dimension).

**Preprocessing parity:** run `open_clip`'s own `preprocess` transforms for images regardless
of any client-side pre-resize, so the image tower always receives correctly-sized/normalized
input. Confirm the model's expected input resolution.

**Fallback:** if faithfully reproducing the envelope proves impractical, fall back to a clean
REST API on the server **plus** a `CasClient` patch in the plugin repo. This expands scope to
a second repo and a plugin release, so it requires explicit re-confirmation before adoption.

## 7. Embedding server details

- `docker/clip-server/`
  - `Dockerfile`: `python:3.11-slim` base + CPU torch wheels + `open_clip_torch` + `fastapi`
    + `uvicorn` + `pillow`; pinned versions.
  - `requirements.txt`: pinned dependency set.
  - `app/`: server implementation (model load, `/post`, `/health`, encoding helpers).
- Endpoints:
  - `POST /post` — Jina-compatible; handles both `text` and `blob` items in one request.
  - `GET /health` — readiness (model loaded); replaces the current Python socket probe in the
    compose healthcheck.
  - `POST /encode/text`, `POST /encode/image` — optional clean endpoints for debugging/tests.
- Startup:
  - Load model; **warm up** with a dummy text and image.
  - **Dimension validation:** assert the loaded model's output dim == `MULTIMODAL_DIMENSION`;
    on mismatch, fail fast with a clear message. This closes the current silent
    dimension-mismatch footgun (a wrong dim corrupts kNN without an obvious error).
- Batching: batch multiple items in a single `/post` request through the model with
  `torch.no_grad()`.

## 8. Configuration & compose changes

- `.env` / `.env.example`:
  - Remove Jina-specific build args (`CLIP_SERVER_BASE`, `TRANSFORMERS_VERSION`).
  - Keep `CLIP_MODEL_NAME`, `MULTIMODAL_DIMENSION`, `CLIP_MIN_SCORE`.
  - Add `CLIP_DEVICE` (default `cpu`), and batch/image-size tunables as needed.
- `config/clip.yaml` / `config/clip.yaml.template`: **remove** (no Jina Flow). Drop the
  clip.yaml rendering step from `bin/setup.sh`.
- `compose.yaml`: `clip_server` builds the new image; healthcheck uses `GET /health`; keep
  the internal `51000` port and the `clip.server.endpoint` default; keep `depends_on` wiring.
- Model cache volume: switch the bind-mounted cache path from Jina's `~/.cache/clip` to the
  `open_clip` / HuggingFace hub download cache directory, preserving persistent/offline reuse.

## 9. Model swap & dimension handling

- Document the H/14 upgrade: set `CLIP_MODEL_NAME=xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k`
  and `MULTIMODAL_DIMENSION=1024`, recreate `clip_server`, and **reindex** (a dimension change
  requires recreating the `content_vector` mapping).
- Improve `bin/init-fess-index.sh` to detect/flag a dimension change (it currently only checks
  field existence), so a swapped dimension does not silently mismatch the existing mapping.

## 10. Theme

No change. `mosaic` is model-agnostic and text-to-image; its searcher badges
(`default`→Keyword, `multi_modal`→Visual, both→Blend) rely on Fess wiring already present in
the stack. PR #25 stands as-is.

## 11. Refactoring / modernization (focused)

- Remove now-dead Jina artifacts: `config/clip.yaml(.template)`, the `transformers` pin, the
  socket healthcheck, the clip.yaml render in `setup.sh`.
- Update `README.md`: remove the text-projection "known limitation" note (once verified
  fixed), refresh the "Model swap" section, the architecture description, and the CLIP-server
  section to describe the custom server.
- Preserve the rest of PR #2's modernization (Fess 15.7-noble, OpenSearch 3.7, nginx
  `content`, `init-fess-index`, env-driven config).

## 12. Testing & verification

1. **Contract / unit tests** (server):
   - Start the server; POST text and image in the Jina envelope; assert the response shape
     matches `CasClient`'s parser and dimension == 512.
   - **Differentiation check** (the currently-broken core): assert that, for the sample
     corpus, a Japanese query like `山の夕日` scores a genuine sunset image higher than an
     unrelated image (e.g. a cat); that Japanese/English synonyms embed close together; and
     that distinct concepts embed far apart. This is the direct regression test for the bug.
2. **End-to-end** (acceptance):
   - `docker compose up -d`, run setup → crawl → reindex.
   - Use **Claude in Chrome** to open the `mosaic` gallery and confirm Japanese queries
     (e.g. 「山の夕日」「猫」) return relevant images with Visual/Blend badges; spot-check a
     couple of English queries for parity.
3. **Optional offline relevance smoke:** embed the ~35 sample images + a few JA/EN queries and
   print top-k, to quantify the improvement over the old `clip-server`.

## 13. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Response-envelope mismatch breaks the drop-in | Read `CasClient` first; golden-fixture contract test; documented fallback (patch plugin, needs re-confirmation) |
| CPU inference latency at query time | B/32 is CPU-adequate; document; H/14 is GPU-only guidance |
| First-boot model download size/time | Persistent cache volume; document expected download |
| Dimension mismatch corrupts kNN silently | Startup dimension validation; `init-fess-index.sh` dimension check |

## 14. Rollout

All changes land in `docker-multimodalsearch`, continuing the PR #2 line of work (same or a
stacked branch off `feature/fess-15.7-multimodal-gallery`). No plugin or theme release is
required for the default path.
