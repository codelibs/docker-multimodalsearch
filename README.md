# Multimodal (Image + Text) Gallery Search on Fess

[Fess](https://fess.codelibs.org/) is an open-source Enterprise Search Server. This
Docker environment runs Fess with a **CLIP-powered multimodal search plugin**, so a
plain text query — in English or Japanese — returns a **visual gallery**: CLIP-matched
images blended with BM25-matched pages, PDFs, and Office documents, each shown by its
thumbnail. The bundled **`mosaic`** static theme renders that gallery (masonry grid,
lightbox, per-result "Keyword / Visual / Blend" badges) instead of a classic result list.

> **Read this first:** this stack pins the `-noble` Fess image variant
> (`ghcr.io/codelibs/fess:15.7.0-noble`), not the default Alpine image. Without it,
> image/PDF/Office thumbnails silently fail to render and the gallery shows broken
> tiles. See [The `-noble` image](#the--noble-image) below.

## Architecture

All five services run on a single Docker Compose network, `multimodal_net`:

```
                            ┌─────────────────────────────┐
   browser ────────────────▶│ fess01                       │  http://localhost:8080
   (search UI, admin UI)    │ ghcr.io/codelibs/fess         │
                            │ :15.7.0-noble                 │
                            │ + fess-webapp-multimodal       │
                            │ + mosaic gallery theme         │
                            └──────┬────────────┬──────────┘
                     index/search  │            │ text & image embeddings
                     (BM25 + kNN)  │            │ (query time + crawl time)
                                   ▼            ▼
                     ┌───────────────────┐   ┌───────────────────────┐
                     │ search01            │   │ clip_server             │
                     │ fess-opensearch      │   │ jinaai/clip-server      │
                     │ :3.7.0               │   │ CLIP model (~1.6 GB     │
                     │ 127.0.0.1:9200        │   │ download on first boot)│
                     │ (loopback only)       │   └───────────────────────┘
                     └─────────┬────────────┘
                               ▲
                               │ checks/creates the content_vector mapping
                               │
                     ┌───────────────────┐
                     │ init-fess-index     │  one-shot: runs once fess01 is
                     │ (alpine + curl/jq)  │  healthy, then exits
                     └───────────────────┘

   fess01 also web-crawls the demo corpus (a manual, documented step):

                     ┌───────────────────┐
   fess01 ──crawl──▶ │ content              │  http://content/  (nginx serving
                     │ (nginx:alpine)       │  ./data/content read-only; not
                     └───────────────────┘  published to the host)
```

- **`search01`** — OpenSearch 3.7 (`ghcr.io/codelibs/fess-opensearch:3.7.0`), roles
  `cluster_manager,data,ingest,ml`. Stores documents and their CLIP vectors and serves
  both the BM25 and kNN branches of every query.
- **`clip_server`** — built from `docker/clip-server/Dockerfile` (stock jinaai/clip-server
  image with pinned `transformers` for multilingual model support). Loads the configured
  CLIP model and turns text and images into embeddings, on demand, for `fess01`.
- **`content`** — a tiny `nginx:alpine` server exposing `./data/content` (read-only)
  as `http://content/` on the internal network only, so Fess's crawler and thumbnail
  generator fetch real HTTP responses (thumbnails render properly) instead of hitting
  the `file://` dead-end.
- **`fess01`** — Fess `15.7.0-noble` with the `fess-webapp-multimodal` plugin
  (installed via `FESS_PLUGINS`, not a local jar) and the `mosaic` theme. Combines the
  `default` (BM25) and `multi_modal` (CLIP) searchers via hybrid rank fusion —
  `rank.fusion.searchers` is intentionally left unset so neither replaces the other.
- **`init-fess-index`** — a one-shot Alpine container that waits for `fess01` to be
  healthy, then bakes the `content_vector` kNN field mapping into the document index
  (the plugin can only inject that mapping when Fess *creates* an index, and Fess core
  auto-creates the index before the plugin registers its rewrite rules — see the
  comments in `compose.yaml` and `bin/init-fess-index.sh`). It is idempotent: it only
  checks whether `content_vector` already exists, so restarts are cheap.

## Getting Started

### Prerequisites

Docker and Git.

### 1. Configure

```sh
git clone https://github.com/codelibs/docker-multimodalsearch.git
cd docker-multimodalsearch
cp .env.example .env
```

`.env` holds every tunable (image tags, `FESS_PLUGINS`, the CLIP model, the theme, heap
sizes, `FESS_ADMIN_PASSWORD`, `DOMAIN`, ...). Defaults work out of the box; edit it now
if you need to change something.

### 2. Run setup

```sh
bash bin/setup.sh
```

This host-side script (no Docker/Fess/OpenSearch calls) is safe to re-run and:

- creates the bind-mount data directories under `./data`;
- renders the live `config/clip.yaml` from `config/clip.yaml.template`, substituting
  `CLIP_MODEL_NAME`;
- seeds `./data/fess/opt/fess/system.properties` from its tracked template **on first
  run only** (sets `theme.default=${THEME_NAME}`; the live file is git-ignored so Fess
  can rewrite it later via Admin > General without conflicting with `git pull`);
- syncs the `${THEME_NAME:-mosaic}` theme from the
  [`fess-themes`](https://github.com/codelibs/fess-themes) repo into
  `./data/fess/usr/share/fess/app/themes/<THEME_NAME>` (mosaic by default);
- drops any stale multimodal plugin jar from a previous run (plugins are loaded via
  `FESS_PLUGINS`, never downloaded by this script).

**About the theme sync — read if `mosaic` is not yet on the `fess-themes` `main`
branch:** `bin/setup.sh` resolves the theme source in this order:

- If `FESS_THEMES_DIR` is set in `.env`, the theme is copied from
  `${FESS_THEMES_DIR}/themes/${THEME_NAME}` in a **local `fess-themes` checkout** —
  useful for theme development, or to pick up a branch that has not been merged yet.
- Otherwise, it shallow-clones `FESS_THEMES_REPO` (default
  `https://github.com/codelibs/fess-themes.git`) at ref `FESS_THEMES_REF` (default
  `main`) and copies `themes/${THEME_NAME}` from there.

If the `mosaic` gallery theme has not yet been merged to `fess-themes` `main`, either:

- point `FESS_THEMES_DIR` at a local `fess-themes` checkout that already has it (e.g.
  a sibling clone on its development branch), **or**
- set `FESS_THEMES_REF` in `.env` to that development branch name before running
  `bin/setup.sh`.

Either way, re-run `bash bin/setup.sh` after changing `FESS_THEMES_DIR`/`FESS_THEMES_REF`
to re-sync, then restart `fess01` if it was already running (see
[Troubleshooting](#troubleshooting) — Fess caches theme bytes).

### 3. Start the stack

```sh
docker compose up -d
```

Watch it come up:

```sh
docker compose ps
docker compose logs -f clip_server fess01 init-fess-index
```

Notes on first boot:

- `docker compose up -d` builds the `clip_server` image locally (adds ~a minute) before
  pulling other images. The image is built once and cached; subsequent starts pull it
  from Docker's local cache and are faster.
- `clip_server` downloads the configured CLIP model (**~1.6 GB** for the default
  model) the first time it starts, caching it in `./data/clip_server/cache`; this can
  take a few minutes. `fess01` only depends on `clip_server` having *started* (not
  healthy), so Fess itself comes up quickly, but multimodal search will not return
  visual matches until the model finishes downloading.
- `init-fess-index` waits for `fess01`'s healthcheck (`/api/v2/health`), then triggers
  a one-time Admin > Maintenance reindex so the document index carries the
  `content_vector` mapping. Confirm it finished with `Exited (0)`:
  ```sh
  docker compose ps -a
  ```

### 4. Seed sample content

```sh
bash bin/fetch-sample-images.sh
```

Populates `./data/content/` with a small CC0/CC-BY/CC-BY-SA/public-domain image set
(animals, vehicles, food, nature, buildings), a few HTML pages, and a sample PDF —
served by the `content` nginx service at `http://content/`. Safe to re-run; already
downloaded files are left alone.

### 5. Crawl (manual step)

There is no crawl-automation container — crawling is a deliberate, one-time step you
run from the Fess Admin UI (`init-fess-index` only prepares the index mapping, it does
not crawl):

1. Sign in at `http://localhost:8080/admin/` (default `admin` / `admin` — you'll be
   asked to set a new password on first sign-in with the default).
2. **Admin > Crawler > Web** > **Create New**: set a **Name** (e.g. `content`) and
   **URLs** to `http://content/`, then **Create**.
3. **Admin > System > Scheduler** > **Default Crawler** > **Start Now**.
4. Watch progress under **Admin > System > Crawling Info** until it finishes.

### 6. Search

Open `http://localhost:8080/` and try a query. Because the default model is
multilingual, try both:

- an English query, e.g. `mountain sunset`
- a Japanese query, e.g. `山の夕日` (or `犬` for "dog")

Both should return a visual gallery mixing CLIP-matched images with any matching
crawled pages/PDF.

### Stop

```sh
docker compose down
```

## The `-noble` image

This stack pins:

```
FESS_IMAGE=ghcr.io/codelibs/fess:15.7.0-noble
```

The **default (Alpine-based) `ghcr.io/codelibs/fess:15.7.0` image ships no
ImageMagick, poppler, or LibreOffice**. Without that tooling, Fess can still generate
HTML thumbnails, but image, PDF, and Office document thumbnails silently fail to
render — the gallery would show blank/broken tiles for most of the demo corpus. The
`-noble` (Ubuntu Noble) variant bundles all three, so image/PDF/Office thumbnails all
render correctly. **Keep the `-noble` variant** (or install that tooling yourself in a
custom image) — it is the single change that makes a thumbnail-first gallery viable.

## Model swap

Default model, set in `.env`:

```
CLIP_MODEL_NAME=xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k
MULTIMODAL_DIMENSION=512
```

`xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k` is multilingual, 512-dimensional, and
CPU-feasible. For maximum retrieval quality (at the cost of a larger download and more
RAM/GPU), swap to `xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k`, which is
1024-dimensional.

`CLIP_MODEL_NAME` and `MULTIMODAL_DIMENSION` must always be changed **together** — the
dimension is baked both into the CLIP encoder and into the `content_vector` kNN field
mapping. To swap models:

1. In `.env`, set both in lockstep, e.g.:
   ```
   CLIP_MODEL_NAME=xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k
   MULTIMODAL_DIMENSION=1024
   ```
2. Re-run `bash bin/setup.sh` to re-render `config/clip.yaml` with the new model name.
3. Recreate `clip_server` (to load the new model) and `fess01` (to pick up the new
   `MULTIMODAL_DIMENSION` in `FESS_JAVA_OPTS`):
   ```sh
   docker compose up -d --force-recreate clip_server fess01
   ```
4. **Reindex manually.** `init-fess-index` already ran once during the initial setup
   and only checks whether the `content_vector` field *exists* — it has no way to
   detect that its dimension changed, so it will **not** re-trigger automatically. Go
   to **Admin > Maintenance** in the Fess admin UI and run **Reindex** (with alias
   replacement) to rebuild the document index with the new vector dimension.
5. Re-crawl (**Admin > System > Scheduler > Default Crawler > Start Now**) so existing
   documents are re-embedded with the new model.

You can also tune `CLIP_MIN_SCORE` (default `0.5`) in `.env`, which sets the minimum
similarity score a CLIP match must reach to be returned.

Three additional optional `.env` variables control the clip-server build and image:
- `CLIP_SERVER_BASE` (default `jinaai/clip-server`): base image to build from.
- `TRANSFORMERS_VERSION` (default `4.30.0`): pinned transformers library version (must
  be compatible with the base image's Python version; multilingual models require
  transformers at load time). English-only CLIP models (e.g. `ViT-B-32::openai`) do not
  need transformers, but the local image includes it harmlessly.
- `CLIP_SERVER_IMAGE` (default `multimodal-clip-server:latest`): name and tag of the
  locally-built image. All three have working defaults and rarely need to be changed.

## Theme

The default theme is `mosaic` (`THEME_NAME=mosaic` in `.env`), a purpose-built gallery
UI: a masonry grid of thumbnails, an image lightbox, and a "Keyword / Visual / Blend"
badge on each result showing whether it was matched by BM25, CLIP, or both. It is
authored and versioned in the separate
[`fess-themes`](https://github.com/codelibs/fess-themes) repository — not committed
into this repo — and synced into `./data/fess/usr/share/fess/app/themes/mosaic` by
`bin/setup.sh` (see [step 2](#2-run-setup) above for the `FESS_THEMES_DIR` /
`FESS_THEMES_REF` options).

To switch to a different theme, set `THEME_NAME` in `.env`, then either edit
`theme.default` in the live `./data/fess/opt/fess/system.properties` (or via
**Admin > General**), or delete that file and re-run `bash bin/setup.sh` to reseed it
from the template.

## Production / TLS

`compose-production.yaml` adds an `https-portal` TLS reverse proxy in front of
`fess01` and a larger OpenSearch heap (`OPENSEARCH_HEAP_PROD`, default `3g`). It is
not part of the base stack; start it as an overlay:

```sh
docker compose -f compose.yaml -f compose-production.yaml up -d
```

Set `DOMAIN` in `.env` (default `multimodal.codelibs.org`). For a custom domain, also
copy `data/https-portal/conf/multimodal.codelibs.org.ssl.conf.erb` to
`data/https-portal/conf/<your-domain>.ssl.conf.erb` — https-portal matches its vhost
template by file name.

## Troubleshooting

- **Thumbnails are missing right after a crawl.** Thumbnail generation is
  asynchronous (a background Fess job runs roughly once a minute); give it up to
  about a minute after the crawl finishes before expecting every tile to be filled in.
  The `mosaic` theme retries a missing thumbnail a few times with backoff before
  showing a fallback icon.
- **`clip_server` takes a while to become useful on first boot.** The CLIP model
  (~1.6 GB for the default model) downloads on first start and is cached in
  `./data/clip_server/cache`; subsequent starts are fast.
- **Can't reach OpenSearch at `http://localhost:9200`.** It's published as
  `127.0.0.1:9200:9200` — loopback only, by design (the search engine runs with
  security disabled). It's reachable from other containers on `multimodal_net` as
  `http://search01:9200`.
- **The theme doesn't change after re-running `bin/setup.sh`.** Fess's
  `StaticThemeResponder` caches the theme's bytes in memory; a resync alone doesn't
  invalidate that cache. Restart `fess01` after syncing a new/updated theme:
  ```sh
  docker compose restart fess01
  ```
- **`init-fess-index` never finishes / times out.** It waits up to `MAX_WAIT` seconds
  (default `900`, i.e. 15 minutes) for `fess01` to become healthy and for the
  `content_vector` mapping to appear, then exits with an error. Check
  `docker compose logs init-fess-index` and `docker compose logs fess01`; once the
  underlying issue is fixed, re-run it with `docker compose up -d init-fess-index`
  (it won't restart automatically — `restart: "no"`).
- **Full-resolution lightbox images don't load from the browser.** The demo `content`
  service is only reachable inside `multimodal_net` (`http://content/`), not from the
  host. The gallery still works — tiles and the lightbox fall back to Fess's own
  same-origin `/thumbnail/` endpoint — but a crawled image's original URL
  (`http://content/...`) won't open directly in a host browser tab.

## Optional: a larger sample dataset with FiftyOne

`bin/fetch-sample-images.sh` seeds a small (~35 image) demo set. For a larger, more
varied gallery, use [FiftyOne](https://voxel51.com/fiftyone/) to pull a bigger sample
from Open Images V7 and drop it into the crawlable content directory:

```sh
pip install fiftyone
fiftyone zoo datasets load open-images-v7 --split validation --kwargs max_samples=1000 -d ./data/fiftyone-export
```

Then copy the exported images into `./data/content/images/` and add links to them
from `./data/content/index.html` before running the crawl in
[step 5](#5-crawl-manual-step). The crawler discovers documents by following links
from `http://content/`, so images in `./data/content/images/` alone (without links)
will not be indexed — you must make them linkable from `index.html` or another
crawlable page.

---

For additional support or information, please visit the
[Fess documentation](https://fess.codelibs.org/).
