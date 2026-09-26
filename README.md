# Multimodal (Image + Text) Gallery Search on Fess

[Fess](https://fess.codelibs.org/) is an open-source Enterprise Search Server. This
Docker environment runs Fess with a **CLIP-powered multimodal search plugin**, so a
plain text query — in English or Japanese — returns a **visual gallery**: CLIP-matched
images blended with BM25-matched pages, PDFs, and Office documents, each shown by its
thumbnail. The bundled **`mosaic`** static theme renders that gallery (masonry grid,
lightbox, per-result "Keyword / Visual / Blend" badges) instead of a classic result list.

> **Read this first:**
>
> - This stack pins the `-noble` Fess image variant
>   (`ghcr.io/codelibs/fess:15.8.0-noble`), not the default Alpine image. Without it,
>   image/PDF/Office thumbnails silently fail to render and the gallery shows broken
>   tiles. See [The `-noble` image](#the--noble-image).
> - **Fess 15.8 moved vector search into the core.** Vectors now live in the core
>   `content_chunk_vector` field, not the plugin's old `content_vector`, and every
>   `content_chunker.*` setting must be passed as `-Dfess.system.*`. If you are coming
>   from the 15.7 version of this stack, read
>   [Upgrading from 15.7](#upgrading-from-157) before you start anything.
> - **Upgrading an existing stack to Fess 15.9?** Its scheduled jobs are still Groovy,
>   which 15.9 no longer runs out of the box. Read
>   [Upgrading from 15.8 to 15.9](#upgrading-from-158-to-159) first.

## Architecture

All five services run on a single Docker Compose network, `multimodal_net`:

```
                            ┌─────────────────────────────┐
   browser ────────────────▶│ fess01                       │  http://localhost:8080
   (search UI, admin UI)    │ ghcr.io/codelibs/fess         │
                            │ :15.8.0-noble                 │
                            │ + fess-webapp-multimodal       │
                            │ + mosaic gallery theme         │
                            └──────┬────────────┬──────────┘
                     index/search  │            │ text & image embeddings
                     (BM25 + kNN)  │            │ (query time + crawl time)
                                   ▼            ▼
                     ┌───────────────────┐   ┌───────────────────────┐
                     │ search01            │   │ clip_server             │
                     │ fess-opensearch      │   │ custom open_clip server │
                     │ :3.8.0               │   │ CLIP model (~1.6 GB     │
                     │ 127.0.0.1:9200        │   │ download on first boot)│
                     │ (loopback only)       │   └───────────────────────┘
                     └─────────┬────────────┘
                               ▲
                               │ reads back the content_chunk_vector mapping
                               │ and fails fast on a mismatch
                     ┌───────────────────┐
                     │ init-fess-verify    │  one-shot: runs once fess01 is
                     │ (alpine + curl/jq)  │  healthy, then exits
                     └───────────────────┘

   fess01 also web-crawls the demo corpus (a manual, documented step):

                     ┌───────────────────┐
   fess01 ──crawl──▶ │ content              │  http://content/  (nginx serving
                     │ (nginx:alpine)       │  ./data/content read-only; not
                     └───────────────────┘  published to the host)
```

- **`search01`** — OpenSearch 3.8 (`ghcr.io/codelibs/fess-opensearch:3.8.0`), roles
  `cluster_manager,data,ingest`. Stores documents and their CLIP vectors and serves both
  the BM25 and kNN branches of every query. Note the **absence of the `ml` role**: all
  embeddings come from `clip_server`, never from OpenSearch ML Commons, so the node does
  not need to load models.
- **`clip_server`** — a custom FastAPI + open_clip server (`docker/clip-server/`) that
  loads the configured OpenCLIP XLM-RoBERTa model natively and serves `POST /post`
  (Jina-compatible), returning L2-normalized text/image embeddings on demand for
  `fess01`. The `fess-webapp-multimodal` plugin talks to it at
  `http://clip_server:51000`. The model is MIT-licensed. First boot downloads ~1.6 GB
  into `./data/clip_server/cache` and requires network access at runtime. It runs as a
  non-root user whose UID/GID default to `1000` and are set to the host user by
  `bin/setup.sh` (overridable via `CLIP_UID`/`CLIP_GID` in `.env`).
- **`content`** — a tiny `nginx:alpine` server exposing `./data/content` (read-only)
  as `http://content/` on the internal network only, so Fess's crawler and thumbnail
  generator fetch real HTTP responses (thumbnails render properly) instead of hitting
  the `file://` dead-end.
- **`fess01`** — Fess `15.8.0-noble` with the `fess-webapp-multimodal` plugin and the
  `mosaic` theme. Combines the `default` (BM25) and `multi_modal` (CLIP) searchers via
  hybrid rank fusion — `rank.fusion.searchers` is intentionally left unset so neither
  replaces the other. `fess01` waits for `clip_server` to be **healthy** (not merely
  started), so on a cold boot it does not come up until the CLIP model has finished
  loading.
- **`init-fess-verify`** — a one-shot Alpine container that waits for `fess01` to be
  healthy, then **reads back** the `content_chunk_vector` kNN mapping from
  `fess.search` and fails fast when the dimension or engine does not match the running
  configuration (it also warns when `index.knn` is not `true`). It changes nothing.
  This replaces 15.7's `init-fess-index`, which had to log into the admin UI and
  trigger a reindex to inject the mapping — see
  [What changed in 15.8](#what-changed-in-158).

## What changed in 15.8

Fess 15.8 owns vector search. The plugin no longer registers a vector field, a searcher
or an index rewrite; it supplies a CLIP embedding provider and an image ingestion path,
and core does the rest.

- **The vector field is `content_chunk_vector`** (a `nested` field with a `knn_vector`
  subfield `vector`), not the plugin's old `content_vector`.
- **The kNN mapping is baked in at index creation.** Core's index template substitutes
  the configured dimension/method/engine/space_type when it *creates* the document
  index, so there is no ordering race between core and the plugin and **no reindex
  workaround**. 15.7's `bin/init-fess-index.sh` is deleted.
- **`bin/init-fess-verify.sh` only verifies.** A clean boot of this stack produces:

  ```
  [init-fess-verify] OK: dimension=512, engine=lucene, space_type=cosinesimil, index.knn=true
  ```

  with exactly one document index and no reindex. If the index predates the current
  configuration, the mapping is frozen and the symptom is "search quietly returns
  nothing" — this container turns that into an explicit failure with the fix in the
  message.

### The config channel (read this before changing anything)

Fess has two `-D` config channels, and `content_chunker.*` uses only one of them:

| Channel | Reaches | Used here for |
|---|---|---|
| `-Dfess.config.<key>` | `fess_config.properties` overrides | `query.facet.fields`, `paging.search.page.size`, … |
| `-Dfess.system.<key>` | the `system.properties` channel (`FessProp#getSystemProperty`) | **every `content_chunker.* key`** |

**`-Dfess.config.content_chunker.*` is silently ignored.** There is no warning; the
setting simply never arrives, and the effect looks like "the vector branch is off".

Equally important: `FessProp#getSystemProperty` reads the **file first** and only falls
back to `-Dfess.system.*`:

```java
ComponentUtil.getSystemProperties().getProperty(key, System.getProperty("fess.system." + key))
```

So a `content_chunker.*` line in `data/fess/opt/fess/system.properties` **wins over**
the `-Dfess.system.*` value from `compose.yaml`, which makes every `.env`-driven value
dead. Never write `content_chunker.*` into that file or into its tracked
`system.properties.template`. (The template shipped here deliberately contains only
`theme.default`, `thumbnail.enabled`, suggest/login/purge keys.)

One consequence worth knowing: no `job.system.property.filter.pattern` is needed any
more. Fess's `ExecJob` forwards every `fess.system.` property to the crawler, thumbnail
and chunk child processes automatically.

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
if you need to change something. See
[Configuration reference](#configuration-reference) for the keys this version added or
renamed.

### 2. Run setup

```sh
bash bin/setup.sh
```

This host-side script is safe to re-run and:

- creates the bind-mount data directories under `./data`;
- seeds `./data/fess/opt/fess/system.properties` from its tracked template **on first
  run only** (sets `theme.default=${THEME_NAME}`; the live file is git-ignored so Fess
  can rewrite it later via Admin > General without conflicting with `git pull`);
- syncs the `${THEME_NAME:-mosaic}` theme from the
  [`fess-themes`](https://github.com/codelibs/fess-themes) repo into
  `./data/fess/usr/share/fess/app/themes/<THEME_NAME>` (mosaic by default);
- **generates `./data/fess/bin/generate-thumbnail`** with `image_size` rewritten to
  `${THUMBNAIL_SIZE}` (see [Thumbnail size](#thumbnail-size));
- drops any stale multimodal plugin jar from a previous run;
- writes `CLIP_UID`/`CLIP_GID` (your host user's UID/GID) into `.env` if absent, so the
  non-root `clip_server` container can write its bind-mounted model cache.

> Unlike the 15.7 version, `bin/setup.sh` **does** talk to Docker: it runs one
> `docker run --rm --entrypoint cat <FESS_IMAGE> …` to read `generate-thumbnail` out of
> the pinned image. It still never talks to a running Fess or OpenSearch, and it never
> downloads plugin jars.

**About the theme sync:** `bin/setup.sh` resolves the theme source in this order:

- If `FESS_THEMES_DIR` is set in `.env`, the theme is copied from
  `${FESS_THEMES_DIR}/themes/${THEME_NAME}` in a **local `fess-themes` checkout** —
  useful for theme development, or to pick up a branch that has not been merged yet.
- Otherwise, it shallow-clones `FESS_THEMES_REPO` (default
  `https://github.com/codelibs/fess-themes.git`) at ref `FESS_THEMES_REF` (default
  `main`) and copies `themes/${THEME_NAME}` from there.

This stack needs **mosaic 2.0.0 or later**. Mosaic 1.x quotes the query whenever a
filter is active, which on 15.8 trips the core query-syntax gate and turns every
filtered search keyword-only.

`fess-themes` `main` follows the newest Fess line: it currently ships mosaic 15.9.x
(`minFessVersion: 15.9`), which also renders on Fess 15.8.0. `fess-themes` has no
per-version tags, and `FESS_THEMES_REF` can only name a branch, so to pin the build
this stack was released with on 15.8 (mosaic 2.0.0), check out `fess-themes` at commit
`ce1e5ca` and point `FESS_THEMES_DIR` at that checkout.

Verify with:

```sh
grep -E '^(version|minFessVersion):' data/fess/usr/share/fess/app/themes/mosaic/theme.yml
```

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
docker compose logs -f clip_server fess01 init-fess-verify
```

Notes on first boot:

- `docker compose up -d` builds the `clip_server` image locally (adds ~a minute) before
  pulling other images. The image is built once and cached; subsequent starts pull it
  from Docker's local cache and are faster.
- `clip_server` downloads the configured CLIP model (**~1.6 GB** for the default model)
  the first time it starts, caching it in `./data/clip_server/cache`; this can take a
  few minutes. `fess01` waits on `clip_server`'s **healthcheck**
  (`condition: service_healthy`, `start_period: 600s`), so on a cold start the whole
  stack blocks until the model is loaded. That is deliberate: it prevents a window in
  which Fess accepts crawls and writes documents with no vectors.
- With the model already cached, a clean boot of this stack reached all-healthy in about
  **45 seconds**. Your numbers will differ with hardware and image-pull state.
- `init-fess-verify` waits for `fess01`'s healthcheck (`/api/v2/health`), then reads the
  mapping back. Confirm it finished with `Exited (0)`:
  ```sh
  docker compose ps -a
  docker compose logs init-fess-verify
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
run from the Fess Admin UI (`init-fess-verify` only checks the mapping, it does not
crawl):

1. Sign in at `http://localhost:8080/admin/` (default `admin` / `admin` — you'll be
   asked to set a new password on first sign-in with the default).
2. **Admin > Crawler > Web** > **Create New**: set a **Name** (e.g. `content`) and
   **URLs** to `http://content/`, then **Create**.
3. **Admin > System > Scheduler** > **Default Crawler** > **Start Now**.
4. Watch progress under **Admin > System > Crawling Info** until it finishes.

On the shipped demo corpus this run produced **43 documents** (37 jpg, 5 html, 1 pdf)
and **41 thumbnails**. Image vectors are written during this crawl, by the crawler
process — not by a scheduled job (see
[The Content Chunk Vector Indexer job](#the-content-chunk-vector-indexer-job)).

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

## Installing the plugin

`FESS_PLUGINS` (default `fess-webapp-multimodal:15.8.0`) is installed by the Fess image
at startup from `https://maven.codelibs.org`: the release repository for a release
version, the snapshot repository for a `-SNAPSHOT` version. Keep the plugin version in
step with `FESS_VERSION`.

To run a locally built jar instead:

1. Leave `FESS_PLUGINS` **empty** in `.env`:
   ```
   FESS_PLUGINS=
   ```
   (`compose.yaml` uses `${FESS_PLUGINS-…}`, so an explicitly-empty value is honoured
   and no plugin download is attempted.)
2. Run `bash bin/setup.sh` **first** — it deletes
   `data/fess/usr/share/fess/app/WEB-INF/plugin/fess-webapp-multimodal-*.jar` on every
   run, so a jar copied in beforehand would be wiped.
3. Build and copy the jar **after** setup:
   ```sh
   cd /path/to/fess-webapp-multimodal
   mvn clean package
   cp target/fess-webapp-multimodal-*.jar \
      /path/to/docker-multimodalsearch/data/fess/usr/share/fess/app/WEB-INF/plugin/
   ```
4. `docker compose up -d` (or `docker compose restart fess01` if it was already up).

Either way, verify the plugin is live by checking that a search response carries
`multi_modal` in its `searcher` field — see [Troubleshooting](#troubleshooting). A
plugin that fails to download does not stop Fess from starting: every container still
reports healthy, and search quietly answers keyword-only.

## When visual search does *not* run

The vector branch is skipped, and the search silently degrades to keyword-only, in each
of these cases. All of them are expected behaviour, not bugs.

| Condition | Why |
|---|---|
| **`sort=` is specified** | The kNN branch is score-ordered and cannot be re-ordered; interleaving score-ordered hits into a sorted list would make the order meaningless. Core appends `sort:<field>` to the query string, which both gates then reject. Verified: `q=red car&sort=last_modified.desc` returns `searcher: ["default"]` only. |
| **The query contains real search syntax** | A quoted phrase, a wildcard, a range, `AND`/`OR`/`NOT`, or a leading `+`/`-`. None of those survive being turned into a single vector. Verified: `"World Landmarks"` returns keyword hits only. |
| **`start >= 100`** | Deep pagination. `RankFusionProcessor` falls back to the main searcher once `start * 2 >= rank.fusion.window_size` (default `200`). |
| **The CLIP server is unreachable** | The search degrades to keyword-only rather than failing. Good for availability, easy to miss — check `searcher` in the response. |

**Not a trigger: facet, label and filetype filters.** On stock 15.8 a `filetype:` term in
the query *would* trip the query-syntax gate — core folds a facet click into the query
string as `label:"x"` — and the vector branch would vanish the moment a user clicked a
filter. This stack's plugin recovers both halves instead: it splits the query with core's
own parser, embeds only the free text, and turns each field-qualified clause into a real
kNN filter (applied both inside the kNN query, for efficient filtering, and on the outer
bool, which is what actually enforces it). This covers any field core's `QueryProcessor`
can filter on — `label`, `host`, `site`, `filetype`, `mimetype`, `lang`, and so on;
there is no allowlist to keep in sync. Verified live: `q=red car filetype:jpg` returns
`searcher: ["multi_modal"]` and only jpg hits. Fess 15.9 moved this query splitter into
the core (`org.codelibs.fess.query.StructuredQuerySplitter`), and plugin 15.9 uses the
core one; the behaviour is the same.

## The Content Chunk Vector Indexer job

Fess 15.8 ships a scheduled job named **Content Chunk Vector Indexer**
(`cronExpression: 0 13 * * *`, `available: false`). **Leave it disabled.** In this stack:

- **Image vectors are written by the crawler**, not by that job. The plugin's
  `CasExtractor` embeds each image during the crawl and `EmbeddingIngester` writes the
  result into `content_chunk_vector` at index time.
- Every image document is also stamped `content_chunk_status=done`, so the job would
  never revisit one even if it ran.
- Enabling it would additionally embed **text** documents and rewrite their `content`
  field into a chunk array — a different feature, with different storage and relevance
  consequences, that this gallery stack does not want.

## The `-noble` image

This stack pins:

```
FESS_IMAGE=ghcr.io/codelibs/fess:15.8.0-noble
```

The **default (Alpine-based) `ghcr.io/codelibs/fess:15.8.0` image ships no ImageMagick,
poppler, or unoconv/LibreOffice**. Without that tooling, Fess can still generate HTML
thumbnails, but image, PDF, and Office document thumbnails silently fail to render — the
gallery would show blank/broken tiles for most of the demo corpus. The `-noble` (Ubuntu
Noble) variant bundles all three, so image/PDF/Office thumbnails all render correctly.
**Keep the `-noble` variant** (or install that tooling yourself in a custom image) — it
is the single change that makes a thumbnail-first gallery viable.

### Thumbnail size

Fess's shipped `generate-thumbnail` script hardcodes `image_size=100x100`, and **there
is no Fess configuration key for it** — `thumbnail.width`/`thumbnail.height` do not
exist in the core and setting them does nothing. 100×100 is far too small for a
thumbnail-first gallery.

`bin/setup.sh` therefore reads the script out of the pinned image, rewrites the
`image_size` line to `${THUMBNAIL_SIZE}` (default `512x512`), writes it to
`./data/fess/bin/generate-thumbnail`, and `compose.yaml` bind-mounts it read-only over
the image's copy. Reading it from the pinned image keeps the script in step with the
Fess version; if the `docker run` fails, setup falls back to the image's original script
and warns.

That script only covers **command-based** generation: images, PDF and Office documents.
**HTML-page thumbnails take a different path entirely** — Fess extracts an `<img>` from
the page and resizes it in Java (`HtmlTagBasedGenerator`), governed by
`thumbnail.html.image.thumbnail.width`/`.height`, whose own defaults are also `100`.
Rewriting `generate-thumbnail` alone therefore leaves every HTML tile in the gallery at
100×100 while image tiles are 512px. `compose.yaml` raises the HTML path separately:

```
-Dfess.config.thumbnail.html.image.thumbnail.width=${THUMBNAIL_PX:-512}
-Dfess.config.thumbnail.html.image.thumbnail.height=${THUMBNAIL_PX:-512}
```

`THUMBNAIL_PX` is a plain pixel count (`512`), not a `WxH` string like `THUMBNAIL_SIZE`.
Keep the two in step when changing either.

To change the size, set `THUMBNAIL_SIZE` and `THUMBNAIL_PX` in `.env`, re-run
`bash bin/setup.sh`, restart `fess01`, and regenerate the thumbnails. Note that a plain
re-crawl only regenerates thumbnails for documents the crawler considers *changed*; to
force a full regeneration, delete the documents first (**Admin > Maintenance**, or
`curl -XPOST 'localhost:9200/fess.search/_delete_by_query?refresh=true' -H 'Content-Type: application/json' -d '{"query":{"match_all":{}}}'`)
and crawl again.

## Configuration reference

Every key lives in `.env`. Only `.env.example` is tracked in the repo — **if you already
have a `.env` from the 15.7 stack, update it by hand**; nothing rewrites it for you.

Keys added or changed in this version:

| Key | Default | Notes |
|---|---|---|
| `FESS_VERSION` | `15.8.0` | **New.** Feeds `ghcr.io/codelibs/fess:${FESS_VERSION}-noble`. |
| `OPENSEARCH_VERSION` | `3.8.0` | **New.** Feeds `ghcr.io/codelibs/fess-opensearch:${OPENSEARCH_VERSION}`. |
| `KNN_K` | `100` | **New.** Neighbours requested per shard (`content_chunker.search.knn.k`). |
| `KNN_ENGINE` | `lucene` | **New.** kNN engine baked into the mapping; also checked by `init-fess-verify`. |
| `THUMBNAIL_SIZE` | `512x512` | **New.** Rewritten into `generate-thumbnail` by `bin/setup.sh`. |
| `CHUNK_SETUP_MAX_WAIT` | `300` | **New.** Seconds `init-fess-verify` waits for the mapping. Replaces `MAX_WAIT`. |
| `CLIP_MIN_COSINE` | `0.12` | **Renamed** from `CLIP_MIN_SCORE` (`0.56`). Units changed — see below. |
| `FESS_PLUGINS` | `fess-webapp-multimodal:15.8.0` | Was `…:15.7.x`. See [Installing the plugin](#installing-the-plugin). |
| `MAX_WAIT` | — | **Removed.** Superseded by `CHUNK_SETUP_MAX_WAIT`. |

Unchanged and still used: `FESS_IMAGE`, `OPENSEARCH_IMAGE`, `NGINX_IMAGE`,
`ALPINE_IMAGE`, `CLIP_SERVER_IMAGE`, `CLIP_MODEL_NAME`, `MULTIMODAL_DIMENSION`,
`CLIP_DEVICE`, `CLIP_MAX_IMAGE_PIXELS`, `CLIP_UID`, `CLIP_GID`, `FESS_HEAP`,
`OPENSEARCH_HEAP`, `OPENSEARCH_HEAP_PROD`, `FESS_ADMIN_PASSWORD`, `SEARCH_PAGE_SIZE`,
`THEME_NAME`, `FESS_THEMES_REPO`, `FESS_THEMES_REF`, `FESS_THEMES_DIR`, `DOMAIN`.

### `CLIP_MIN_COSINE`: the units changed

15.7's `CLIP_MIN_SCORE` was an **engine score**. 15.8's
`content_chunker.search.min_score` is a **raw cosine similarity** in `0..1`, and core
converts it to the engine's scale itself. With `lucene` + `cosinesimil` — what this
stack uses — the engine score is `(1 + cos) / 2`, so:

```
0.56 (old engine score)  ->  2 * 0.56 - 1  =  0.12 (new cosine)
```

Verified on this stack: for `mountain sunset`, `sunset.jpg` has cosine `0.18587` and
Fess reports `score = 0.5929352`, which is exactly `(1 + 0.18587) / 2`. If you had tuned
`CLIP_MIN_SCORE`, convert it with `2 * old - 1` rather than copying the number across.

(With a `faiss` engine the conversion is `1 / (2 - cos)` instead, and with a non-cosine
`space_type` the cutoff is skipped with a warning. This stack pins `cosinesimil`.)

## Upgrading from 15.8 to 15.9

Fess 15.9 moved the Groovy script engine out of core into the `fess-script-groovy`
plugin and made JavaScript the default script type. An upgrade does not rewrite stored
settings, so a 15.8 install keeps Groovy on all 14 bundled scheduled jobs (and on any
data config you created without a `script_type`). This stack does not get the Groovy
plugin: the `WEB-INF/plugin` bind mount hides the copy baked into the 15.9 image. After
the upgrade, the Default Crawler ends with `fail`, and the only traces are a startup WARN
(`Settings use the script engine groovy, which is not registered`) and
`groovy is not found` per job. Search keeps working, so this is easy to miss.

The index, the stored vectors and the thumbnails carry over as they are; the upgrade
needs no reindex and no re-crawl. Switch the stored scripts to JavaScript once, right
after the upgrade:

1. In `.env`, set `FESS_VERSION=15.9.0` and
   `FESS_PLUGINS=fess-webapp-multimodal:15.9.0` (and `FESS_IMAGE`, if you set it).
2. Re-run setup (it regenerates `generate-thumbnail` from the new image and re-syncs the
   theme) and start the stack:
   ```sh
   bash bin/setup.sh
   docker compose up -d
   ```
3. Create an access token for the admin API: **Admin > System > Access Token** >
   **Create New**, with the permission `{role}admin-api`.
4. Run the migration (it needs `python3` on the host):
   ```sh
   export FESS_ACCESS_TOKEN=<the token>
   bash bin/migrate-to-javascript.sh --dry-run   # lists what would change
   bash bin/migrate-to-javascript.sh
   docker compose restart fess01                 # optional: clears the startup warning
   ```
   Set `FESS_ENDPOINT` if Fess is not at `http://localhost:8080`. Delete the token
   afterwards if you have no other use for it.

`bin/migrate-to-javascript.sh`:

- sets every scheduled job whose script type is Groovy (or unset) to JavaScript. The two
  Groovy-only constructs in the bundled 15.8 jobs are rewritten on the way — the `1000L`
  long literal in *Thumbnail Purger* and the `org.opensearch` package that Fess 15.9
  replaced with its own fork in *Index Exporter* — so the result is exactly the job set
  Fess 15.9 ships;
- adds `script_type=javascript` to the Parameter of every data config that has none (or
  `groovy`);
- prints every setting it changes, changes nothing on a second run, and refuses to run
  against Fess 15.8, which has no JavaScript engine.

A job or handler script you customized with other Groovy syntax is switched as well and
has to be rewritten by hand. The alternative is to keep Groovy: append
`fess-script-groovy:15.9.0` to `FESS_PLUGINS` (space-separated).

A fresh 15.9 install needs none of this: its jobs are created as JavaScript.

**Trying 15.9 before its release.** The `.env.example` pins stay at 15.8.0 until 15.9.0
is released. To run the development build, set
`FESS_IMAGE=ghcr.io/codelibs/fess:snapshot-noble`, `FESS_VERSION=15.9.0` and
`FESS_PLUGINS=fess-webapp-multimodal:15.9.0-SNAPSHOT`.

## Upgrading from 15.7

Vector search moved from the plugin into the core, so nearly every setting moved with
it. `compose.yaml` in this repo is already migrated — this table is for anyone carrying
a customised deployment forward.

| 15.7 (plain `-D`) | 15.8 (`-Dfess.system.*`) |
|---|---|
| `clip.server.endpoint` | `content_chunker.embedding.clip.api.url` |
| `clip.image.width` / `.height` / `.max_width` / `.max_height` / `.format` | `content_chunker.embedding.clip.image.width` / `.height` / `.max_width` / `.max_height` / `.format` |
| `fess.multimodal.content.dimension` | `content_chunker.embedding.dimension` |
| `fess.multimodal.content.method` / `.engine` / `.space_type` | `content_chunker.search.knn.method` / `.engine` / `.space_type` |
| `fess.multimodal.content.field` | **Removed** — the field is always `content_chunk_vector` |
| `fess.multimodal.min_score` (engine score) | `content_chunker.search.min_score` (**raw cosine** — see [above](#clip_min_cosine-the-units-changed)) |

Also removed:

- **`-Dfess.config.job.system.property.filter.pattern`** — no longer needed. `ExecJob`
  forwards the `fess.system.` prefix to child processes automatically.
- **`-Dthumbnail.width` / `-Dthumbnail.height`** — these keys never existed in the Fess
  core and did nothing. Use `THUMBNAIL_SIZE` (see [Thumbnail size](#thumbnail-size)).

Newly required:

- **`-Dfess.system.content_chunker.enabled=true`** and
  **`-Dfess.system.content_chunker.search.enabled=true`** turn the core's chunk pipeline
  and its search branch on. `content_chunker.search.enabled` is read once at startup, so
  enabling it later needs a restart.
- **`-Dfess.system.content_chunker.embedding.name=clip`** points core's
  `EmbeddingClientManager` at the plugin's `clipEmbeddingClient`.

Migration steps:

1. Update `.env` (see [Configuration reference](#configuration-reference)); convert
   `CLIP_MIN_SCORE` to `CLIP_MIN_COSINE`.
2. Remove any `content_chunker.*` lines from
   `data/fess/opt/fess/system.properties` — file values win over `-Dfess.system.*`.
3. `bash bin/setup.sh` (regenerates `generate-thumbnail` and re-syncs the theme; make
   sure you get **mosaic 2.0.0**).
4. Start the stack. The 15.7 index has no `content_chunk_vector` field, so
   `init-fess-verify` will fail with an explicit message. Run **Admin > Maintenance >
   Reindex** with *Update aliases* checked to recreate the index with the new mapping.
5. **Re-crawl.** A reindex copies documents; it does not recompute embeddings, and 15.7's
   `content_vector` values cannot be carried into `content_chunk_vector`.

## Model swap

Default model, set in `.env`:

```
CLIP_MODEL_NAME=xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k
MULTIMODAL_DIMENSION=512
```

`xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k` is multilingual, 512-dimensional, and
CPU-feasible. For maximum retrieval quality (at the cost of a larger download and more
RAM/GPU), swap to `xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k`, which is
1024-dimensional. The H/14 model is significantly heavier to run — a GPU is
recommended; set `CLIP_DEVICE=auto` so `clip_server` uses one if available and falls
back to CPU otherwise.

`CLIP_MODEL_NAME` and `MULTIMODAL_DIMENSION` must always be changed **together** — the
dimension is baked both into the CLIP encoder and into the `content_chunk_vector` kNN
field mapping, and the mapping is frozen when the index is created. To swap models:

1. In `.env`, set both in lockstep, e.g.:
   ```
   CLIP_MODEL_NAME=xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k
   MULTIMODAL_DIMENSION=1024
   CLIP_DEVICE=auto
   ```
2. Rebuild and recreate `clip_server` to load the new model, then recreate `fess01` to
   pick up the new `MULTIMODAL_DIMENSION` in `FESS_JAVA_OPTS`:
   ```sh
   docker compose up -d --build clip_server
   docker compose up -d --force-recreate fess01
   ```
3. **Recreate the index mapping.** The existing index still carries the old dimension;
   the mapping cannot be changed in place. Go to **Admin > Maintenance** in the Fess
   admin UI and run **Reindex** (with alias replacement) to recreate the index with
   `content_chunk_vector.vector` at the new dimension. `init-fess-verify` is what tells
   you this is needed — it fails with `dimension mismatch: index=…, configured
   MULTIMODAL_DIMENSION=…`. Re-run it after the reindex with
   `docker compose up -d init-fess-verify`.
4. **Re-crawl** (**Admin > System > Scheduler > Default Crawler > Start Now**). This is
   what actually repopulates the vectors: a reindex only copies existing documents
   between indices — it does not recompute embeddings, and copying an existing 512-dim
   vector into the new 1024-dim field fails outright, so the old vectors cannot be
   carried forward at all. Re-crawling re-embeds every document against the running
   `clip_server`, producing correctly-sized vectors.

You can also tune `CLIP_MIN_COSINE` (default `0.12`) in `.env`, the minimum **cosine
similarity** a CLIP match must reach to be returned; its ideal cutoff shifts with the
model, so re-check it after any swap.

### Upgrading an existing deployment

Any change to the `clip_server` image or `CLIP_MODEL_NAME` re-embeds the vector space —
**even when `MULTIMODAL_DIMENSION` stays the same**. The new server's embeddings are
not numerically comparable to the old one's, so vectors already indexed by the previous
server are inconsistent with the query vectors the new server produces; kNN matches
degrade instead of failing loudly, which makes this easy to miss. `init-fess-verify`
cannot catch this — the dimension is unchanged.

After upgrading `clip_server` or its model:

1. Delete the crawled documents and **re-crawl** rather than reindexing. A Fess
   reindex (**Admin > Maintenance > Reindex**) only copies documents from one index to
   another — it does not recompute embeddings — so it cannot fix vectors produced by
   the old server. Re-crawling (**Admin > System > Scheduler > Default Crawler >
   Start Now**) re-embeds every document against the currently running `clip_server`.
2. Re-check `CLIP_MIN_COSINE` in `.env` — its ideal cutoff shifts with the model.
3. It's safe to clear the old `./data/clip_server/cache` contents. That directory is
   bind-mounted to the server's model cache; the new server uses a different cache
   layout, so stale bytes from the previous model are never reused.

## Theme

The default theme is `mosaic` (`THEME_NAME=mosaic` in `.env`), a purpose-built
gallery UI: a masonry grid of thumbnails, an image lightbox, and a "Keyword / Visual /
Blend" badge on each result showing whether it was matched by BM25, CLIP, or both. It is
authored and versioned in the separate
[`fess-themes`](https://github.com/codelibs/fess-themes) repository — not committed into
this repo — and synced into `./data/fess/usr/share/fess/app/themes/mosaic` by
`bin/setup.sh` (see [step 2](#2-run-setup) for the `FESS_THEMES_DIR` / `FESS_THEMES_REF`
options).

Two details tie the theme to this stack:

- **Badges read the `searcher` field.** `default` → *Keyword*, `multi_modal` → *Visual*,
  both → *Blend*. That mapping is why the plugin's `ClipChunkSearcher#getName()` returns
  `"multi_modal"` rather than letting the base class derive a name from the class. The
  field only reaches the API because `compose.yaml` sets
  `-Dfess.config.query.additional.api.response.fields=searcher`; without it, mosaic
  silently omits every provenance-driven element and still works as a normal search UI.
- **The query is sent verbatim.** Mosaic 1.x wrapped a multi-word query in quotes
  whenever a filter was active — a workaround for a 15.7 inner-hits collision. On 15.8
  those quotes trip the core's query-syntax gate and kill the vector branch on **every**
  filtered search, so 2.0.0 removed the transform (hence the major version bump and
  `minFessVersion: 15.8`).

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

| Symptom | What to check |
|---|---|
| **No images at all in the gallery** | Are any vectors indexed?<br>`curl -s localhost:9200/fess.search/_count -H 'Content-Type: application/json' -d '{"query":{"nested":{"path":"content_chunk_vector","query":{"exists":{"field":"content_chunk_vector.vector"}}}}}'` |
| **Vectors are not being written** | `docker compose logs fess01 \| grep -i "clip\|embedding"` |
| **The vector branch is not being used** | Look at `searcher` in the `/api/v2/search` response. `["default"]` alone means the branch was skipped — see [When visual search does *not* run](#when-visual-search-does-not-run). |
| **Dimension mismatch** | `docker compose logs init-fess-verify` says so explicitly, with the fix. |
| **`clip_server` is unhealthy** | From inside the network: `docker compose exec fess01 curl -s clip_server:51000/health` |

- **Thumbnails are missing right after a crawl.** Thumbnail generation is asynchronous
  (a background Fess job runs roughly once a minute); give it up to about a minute after
  the crawl finishes before expecting every tile to be filled in. The `mosaic` theme
  retries a missing thumbnail a few times with backoff before showing a fallback icon.
  If thumbnails are *tiny*, `data/fess/bin/generate-thumbnail` was not generated — check
  `bin/setup.sh`'s output for the warning.
- **`clip_server` takes a while to become useful on first boot.** The CLIP model
  (~1.6 GB for the default model) downloads on first start and is cached in
  `./data/clip_server/cache`; subsequent starts are fast. Because `fess01` waits on its
  healthcheck, the whole stack is slow to come up on that first boot only.
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
- **A `content_chunker.*` setting has no effect.** Two traps, both silent: it must be
  `-Dfess.system.…`, not `-Dfess.config.…`; and a matching line in
  `data/fess/opt/fess/system.properties` overrides it. See
  [The config channel](#the-config-channel-read-this-before-changing-anything).
- **`init-fess-verify` never finishes / times out.** It waits up to
  `CHUNK_SETUP_MAX_WAIT` seconds (default `300`) for the `fess.search` mapping to
  appear, then exits with an error. Check `docker compose logs init-fess-verify` and
  `docker compose logs fess01`; once the underlying issue is fixed, re-run it with
  `docker compose up -d init-fess-verify` (it won't restart automatically —
  `restart: "no"`).
- **Full-resolution lightbox images don't load from the browser.** The demo `content`
  service is only reachable inside `multimodal_net` (`http://content/`), not from the
  host. The gallery still works — tiles and the lightbox fall back to Fess's own
  same-origin `/thumbnail/` endpoint — but a crawled image's original URL
  (`http://content/...`) won't open directly in a host browser tab.

## What works

Crawling and indexing, image (CLIP) vector generation into the core
`content_chunk_vector` field, kNN wiring verified at boot, thumbnails at
`${THUMBNAIL_SIZE}`, the gallery UI, keyword (BM25) search, hybrid rank fusion with
per-result searcher badges, filtered visual search (facet/label/filetype filters keep
the vector branch alive), and multilingual (including Japanese) text→image relevance —
the custom `clip_server` produces well-differentiated embeddings across languages, so
relevance is not limited to English.

The cases where the search deliberately falls back to keyword-only are listed under
[When visual search does *not* run](#when-visual-search-does-not-run).

## Optional: a larger sample dataset with FiftyOne

`bin/fetch-sample-images.sh` seeds a small (~37 image) demo set. For a larger, more
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
