# docker-multimodalsearch Modernization + `mosaic` Gallery Theme — Design

- Date: 2026-07-02
- Status: Proposed (awaiting review)
- Scope: two repositories — `codelibs/docker-multimodalsearch` (infra modernization) and `codelibs/fess-themes` (new `mosaic` StaticTheme). `fess-webapp-multimodal` is **not** modified.

## 1. Goal

Modernize the `docker-multimodalsearch` demo to the current Fess/OpenSearch line and give it a purpose-built UI that best expresses **multimodal search**: a user types text (often Japanese) and gets back a **visual gallery** of results — CLIP-matched images shown by their thumbnails, blended with BM25-matched pages/PDFs/Office docs — with a considered fallback for documents that have no thumbnail.

Two properties matter equally: (a) the UI should make "multimodal search" legible and pleasant, and (b) the stack should be **easy to stand up and understand** (`docker compose up -d` just works).

## 2. Current state and problems

`docker-multimodalsearch` today is minimal (7 tracked files) and stale:

- `ghcr.io/codelibs/fess:15.4.0` (Alpine), `fess-opensearch:2.15.0`, plugins pinned at `14.15.0` in `bin/setup.sh` — version-mismatched.
- No `.env`, no healthchecks, no `depends_on` conditions, no init automation, no `system.properties` template, **no theme** (stock Fess UI).
- Manual reindex is required after first boot (Fess DI boot-order: the doc index is created before the multimodal plugin registers its `knn_vector` rewrite, so the index lacks `content_vector` until a reindex).
- The FiftyOne sample-data volume mount is commented out (broken), and `bin/setup.sh` chowns a leftover `WEB-INF/view/semantic` dir that the compose file never mounts.
- Multimodal embeddings come from a **Jina `clip-server`** container (CLIP ViT-B/32, 512-dim) — **not** OpenSearch ml-commons. Text queries are turned into CLIP text embeddings and run as KNN over stored image vectors (the plugin overrides Fess's term/phrase query commands). Default is English-only.

## 3. Reference blueprints

- **`docker-semanticsearch` PR #1** — the proven modernization pattern: `.env`-driven three-layer config, idempotent Alpine init containers + `depends_on` health/completion ordering, tracked `system.properties.template` (git-ignored live file), a theme **synced from `fess-themes`** (not committed), and a production TLS overlay.
- **`fess-themes` PR #24 (`semanticlens`)** — the StaticTheme blueprint: self-contained SPA on `/api/v2/*`, strict CSP, i18n key-parity across 16 locales, graceful degradation on an optional API field, and the Fess core StaticTheme contracts (`theme.yml` manifest, `BundledBootstrapThemeTest` markers, `LabelMessageThemeParityTest`).

`mosaic` is to multimodal search what `semanticlens` is to hybrid semantic search: same scaffold, different signature UX.

## 4. Key decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | **Fess image `ghcr.io/codelibs/fess:15.7.0-noble`** (not the default Alpine) | The stock Alpine image ships **no thumbnail-rendering tooling**; only HTML thumbnails work, and image/PDF/Office thumbnails silently fail (with a 24h negative cache). `-noble` bundles ImageMagick + poppler + LibreOffice, so image + PDF + Office thumbnails all render. This is the single change that makes a gallery viable. Parameterized in `.env`. |
| 2 | OpenSearch → `ghcr.io/codelibs/fess-opensearch:3.7.0` | Matches Fess 15.7; keep `node.roles=cluster_manager,data,ingest,ml`; publish `9200` **loopback-only**. |
| 3 | Plugin `fess-webapp-multimodal:15.7.0` via `FESS_PLUGINS` env | Latest on Maven Central, version-matches Fess 15.7. Removes the stale jar download from `bin/setup.sh`. |
| 4 | **Hybrid ranking** — leave `rank.fusion.searchers` unset (`default` + `multi_modal`) | Mixed corpus: BM25-matched text docs and CLIP-matched images both surface. Genuinely multimodal, not image-only. |
| 5 | Fix the searcher response prop → `-Dfess.config.query.additional.api.response.fields=searcher` (the `.api.` variant) | The current stack sets the non-`api` variant, which only feeds the legacy/JSP path — so `/api/v2/search` never returns `searcher`. The `.api.` variant surfaces per-hit `searcher` (`multi_modal`/`default`), which the theme feature-detects to badge each result Visual / Keyword / Blend. |
| 6 | **Default CLIP model `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k`** (512-dim, multilingual) | Servable natively by the existing Jina `clip-server` (weights from Jina's own S3 — reliable), **same 512 dimension** (no mapping/`content.dimension` change), CPU-feasible on a laptop, and **outranks Japanese-specialized CLIP models on Japanese text→image retrieval** (STAIR benchmark). Note the exact key uses hyphens: `laion5b-s13b-b90k`. |
| 7 | Model + dimension parameterized in `.env` and kept in lockstep | `CLIP_MODEL_NAME` → injected into `config/clip.yaml`; `MULTIMODAL_DIMENSION` → injected into `-Dfess.multimodal.content.dimension`. Swap to `xlm-roberta-large-ViT-H-14::frozen_laion5b_s13b_b90k` (1024-dim) for max quality (needs reindex + more RAM/GPU). SigLIP 2 documented as a future custom-server option only (not Jina-servable). |
| 8 | **Demo content via a tiny `nginx:alpine` service**, web-crawled by Fess | Web crawl yields real `http://` URLs → full-size lightbox works **and** thumbnails generate. Avoids the `file://` dead-end (file crawls can't serve originals to the browser). Reproducible and offline-friendly. |
| 9 | **No `fess-webapp-multimodal` change; search-by-image deferred** | Per direction: rely on thumbnails, not a new upload endpoint. `CasClient.getImageEmbedding()` exists but is unused at search time; wiring it up would need a new plugin Action + a locally-built jar, which breaks the clean "plugins from Maven" story. The theme still ships a **feature-detected, hidden** image-drop affordance, ready to light up if such an endpoint ever ships. |
| 10 | **Theme name `mosaic`**, authored in `fess-themes/themes/mosaic`, synced into the stack via `bin/setup.sh` | Consistent with the `semanticlens`/`nomadkit` ecosystem; reusable by others; separate `fess-themes` PR. |

## 5. Architecture

```
                      multimodal_net (bridge)
 ┌──────────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────────┐
 │  search01    │   │ clip_server  │   │   content     │   │      fess01      │
 │ OpenSearch   │   │ jina clip    │   │ nginx:alpine  │   │ Fess 15.7-noble  │
 │ 3.7.0        │   │ multilingual │   │ serves        │   │ + multimodal     │
 │ ml,ingest    │   │ CLIP 512-dim │   │ ./data/content│   │   plugin 15.7.0  │
 │ :9200(loopbk)│   │ :51000       │   │ :80 (http)    │   │ :8080            │
 └──────┬───────┘   └──────┬───────┘   └───────┬───────┘   └───────┬──────────┘
        │ healthy          │ healthy           │ (crawl target)    │ healthy
        └──────────────────┴───────────────────┴───────────────────┘
                                   │ depends_on (health/completed)
                        ┌──────────┴───────────┐
                        │   init-fess-index    │  one-shot alpine:
                        │  automate the reindex │  logs into Fess, POSTs
                        │  (knn mapping fix)    │  Admin>Maintenance reindex,
                        └───────────────────────┘  waits for content_vector
```

Startup ordering is enforced by `depends_on` conditions so `docker compose up -d` alone yields a working, thumbnail-capable, hybrid multimodal stack. No `model_id` entrypoint handoff is needed (CLIP is not ml-commons), so there is **no `fess-entrypoint.sh` wrapper** — a simplification versus `docker-semanticsearch`.

## 6. The `mosaic` theme (`fess-themes/themes/mosaic`)

### 6.1 Concept

*"See your whole corpus at a glance."* A thumbnail-first visual gallery. A text query returns a mosaic of results — CLIP-matched images beside BM25-matched pages/PDFs/Office docs — each shown by its Fess thumbnail, with a clean typed card for thumbnail-less documents. Degrades to a valid general-purpose theme when the multimodal signals are absent.

### 6.2 Results — masonry gallery (default view)

- **Tile image source:** the same-origin, ACL-safe, normalized endpoint `GET /thumbnail/?docId=<doc_id>&queryId=<query_id>` (`query_id` from the search response `env.query_id`; it is required). Rendered with a `blank.png`-style placeholder, `IntersectionObserver` lazy-loading, and **404 → retry with backoff** (~2s→5s→15s, capped near one job cycle) because thumbnail generation is asynchronous (a Fess job renders them roughly every minute). Gate rendering on the config `thumbnailEnabled` flag **and** a non-empty per-hit `thumbnail` field.
- **Full-resolution upgrade for images:** for image-mimetype hits (web-crawled → `url_link` is a direct image URL), the tile/lightbox may load the full-resolution image from `url_link` for crispness. This requires the CSP `img-src` to allow the crawl origins (see 6.6).
- **Fallback tile (no thumbnail):** a typed card — a mimetype/`filetype` → icon (mirroring the `docuforge` theme's `sourceIcon` FontAwesome map, since Fess core has no filetype-icon convention) + `content_title` + `content_description` + `site_path`. The theme owns a small icon map.
- **Searcher badge (feature-detected):** a subtle corner cue derived from the per-hit `searcher` field — `default` → **Keyword**, `multi_modal` → **Visual**, both → **Blend**. Icon + text (never color alone; WCAG 1.4.1). Hidden entirely when no hit carries `searcher` (keyword-only deployments).
- **Optional composition summary:** a small `aria-live` line ("N results · mostly visual / balanced / mostly keyword"), read-only, derived from the current page's `searcher` mix. Secondary to the gallery.

### 6.3 Lightbox

Click a tile → an accessible overlay (focus-trapped, `Esc`/backdrop to close, arrow-key next/prev) showing the **full-size image** (`url_link` for image docs) or a large thumbnail plus a metadata panel: `content_title`, `url_link`, `mimetype`/`filetype`, `content_length`, `last_modified`, `score`, and the searcher badge. Actions: Open original (`url_link`, new tab), Cache (if `has_cache`), Favorite (`favorite_count`, POST when authenticated).

### 6.4 Views and inherited plumbing

- **List toggle** (`⚏ grid` / `≣ list`): a detailed list view (title / snippet / site) for text-heavy result sets; grid is the default.
- **Home hero:** a multimodal-themed animated band (a text stream and image tiles converging into a shared "embedding space" motif), a glowing search pill wrapping the real `#contentQuery`, a typewriter cycling localized visual example queries, and three preview cards (Keyword / Visual / Blend). Respects `prefers-reduced-motion`, decorative elements `aria-hidden`, animation paused when the view is hidden or the tab is backgrounded.
- **Lightweight filter rail:** count-free File type / Updated / Size groups sourced from `GET /api/v2/ui/config` (`filetype_options`, `facet_views`) so groups stay populated even for vector-heavy results whose BM25 facet buckets are empty; plus the label facet from `env.facet_field`. Slim/collapsible; offcanvas on mobile. No counts (they'd be misleading on the vector side).
- **Ported from `semanticlens`/`nomadkit` to contract:** suggest dropdown (`env.suggest_words[].text`), pagination (`prev_page`/`next_page`/`page_numbers`/`page_number`), search-options drawer, login modal, cache viewer (sandboxed iframe), RAG-chat column (feature-flagged via `features.rag_chat_enabled`; off by default here), the `compat.js` Bootstrap-JS shim, and `app.js`/`api.js`/`router.js`/`i18n.js`/`format.js` (`/api/v2` client, CSRF, XSS-safe rendering).
- **Deferred image-drop UI:** present but hidden, feature-detected on the (currently absent) image-search endpoint.

### 6.5 API fields consumed

Per-hit (`env.data[]`): `doc_id`, `content_title`, `content_description`/`digest`, `url_link`/`url`, `site_path`/`site`, `thumbnail` (presence gate), `mimetype`, `filetype`, `content_length`, `last_modified`/`created`, `score`, `searcher` (optional), `has_cache`, `favorite_count`. Envelope: `env.record_count`(+ `record_count_relation`), `env.query_id` (required for thumbnails), `env.facet_field`, pagination fields, `env.suggest_words[].text`. Config (`/api/v2/ui/config`): `csrf_token`, `features` flags, `filetype_options`, `facet_views`, `thumbnailEnabled`.

### 6.6 CSP (deliberate deviation from `semanticlens`)

A visual-search theme must display crawled imagery, so `img-src` is widened: `img-src 'self' data: https: http:`. Everything else stays strict — `script-src 'self'` (no inline JS; `compat.js` classic + `app.js` module only), `font-src 'self'` (system-font stack, no web fonts), `connect-src 'self'`, `frame-src blob:`/`child-src blob:` (cache-viewer iframe), `base-uri 'self'`. This widening is documented in the theme README as intentional and purpose-scoped.

### 6.7 Contracts the theme must satisfy

- `theme.yml`: `apiVersion: fess.codelibs.org/v1`, `kind: StaticTheme`, `name: mosaic` (`^[a-z0-9][a-z0-9_-]{0,63}$`), semver `version`, `entry: index.html`, `spaFallback: true`, `type: static`, `supportedLocales` including at least `en`+`ja`, `minFessVersion: "15.7"`, `thumbnail: thumbnail.png`.
- `index.html` must contain the `BundledBootstrapThemeTest` string markers (search error/loading, suggest dropdowns, facet offcanvas + `data-bs-toggle="offcanvas"`, search-options fieldset IDs, CSP `frame-src blob:`/`child-src blob:`, no `rel="search"`) and the required asset filenames (`app.js api.js i18n.js auth.js search.js chat.js styles.css`, `messages.en.json`, `messages.ja.json`).
- **i18n key-set parity across all 16 locales** (`LabelMessageThemeParityTest`), including new `mosaic`-specific namespaces (gallery/lightbox/searcher/hero/example keys).
- Packaging via `scripts/package.sh mosaic` → `dist/mosaic-<version>.zip` with `theme.yml` at the root; `README.md`/`DESIGN.md` excluded.

### 6.8 Visual identity

Distinct from `semanticlens`'s cool indigo. `mosaic` leans into an image-forward, gallery aesthetic: a neutral, low-chroma surface so thumbnails carry the color, with a single accent for interactive elements and three source-of-match hues for the badges (Keyword / Visual / Blend), each icon+text and chosen to be distinct under common color-vision deficiencies. System-font stack (CSP), responsive breakpoints reimplemented in `styles.css`, `prefers-reduced-motion` honored throughout. Final palette/typography to be refined during implementation and verified in-browser. The `logo`/`thumbnail` assets start as placeholders (branding art is a follow-up, as in `semanticlens`).

## 7. Infra — `docker-multimodalsearch`

### 7.1 `.env.example` (single source of tunables, all `${VAR:-default}`)

Image tags (`FESS_VERSION`/variant, `OPENSEARCH_VERSION`, `NGINX_VERSION`, `ALPINE_VERSION`), `FESS_PLUGINS`, `CLIP_MODEL_NAME` + `MULTIMODAL_DIMENSION` (lockstep), `CLIP_MIN_SCORE`, `THEME_NAME=mosaic`, `FESS_THEMES_REF`/`REPO`/`DIR`, heap (dev/prod), `FESS_ADMIN_PASSWORD`, `MAX_WAIT`, `DOMAIN`.

### 7.2 `compose.yaml` (rewrite)

Services on `multimodal_net`, with healthchecks and ordering:
- **`search01`** — OpenSearch 3.7, `ml`+`ingest` roles, security disabled, memlock/nofile ulimits, `/_cluster/health` healthcheck, `127.0.0.1:9200:9200`.
- **`clip_server`** — Jina clip-server, model from `CLIP_MODEL_NAME` (injected into a rendered `clip.yaml`), cache volume, healthcheck; GPU `deploy` block kept commented for opt-in.
- **`content`** — `nginx:alpine` serving `./data/content` read-only at `:80` (internal); the web-crawl target.
- **`fess01`** — `fess:15.7.0-noble`, `FESS_PLUGINS=fess-webapp-multimodal:15.7.0`, corrected `FESS_JAVA_OPTS` (`-D` block, see 7.3), `SEARCH_ENGINE_HTTP_URL=http://search01:9200`, `/api/v2/health` healthcheck, and a **persisted, writable `thumbnails` volume** (`fess.var.path`/`fess.thumbnail.path`) so generated thumbnails survive restarts. Bind-mounts the synced `themes/${THEME_NAME}` dir.
- **`init-fess-index`** — one-shot alpine (curl+jq): waits for `fess01` healthy, logs in via the LastaFlute form flow (extracting `TRANSACTION_TOKEN`), POSTs Admin > Maintenance reindex with `replaceAliases=on`, waits for `content_vector` to appear in the mapping. Idempotent (no-ops if the vector field already exists). `restart: "no"`.

### 7.3 `FESS_JAVA_OPTS` `-D` block

- `fess.config.*`: cache off, `adaptive.load.control`, `query.facet.fields=label,host`, **`query.additional.api.response.fields=searcher`** (corrected), initial admin password, thumbnail sizing (`-Dthumbnail.width`/`height` for the pure-Java HTML generator), `job.system.property.filter.pattern=fess.multimodal.*|clip.*`.
- `fess.multimodal.*`: `content.field=content_vector`, `content.dimension=${MULTIMODAL_DIMENSION}`, `content.method=hnsw`, `content.engine=lucene`, `content.space_type=cosinesimil`, `min_score=${CLIP_MIN_SCORE}`.
- `clip.server.endpoint=http://clip_server:51000`.
- `rank.fusion.searchers` intentionally **unset** (hybrid).

### 7.4 `bin/setup.sh` (rewrite)

Create bind-mount dirs (incl. `content`, `thumbnails`); **sync `mosaic` from `fess-themes`** (local `FESS_THEMES_DIR` checkout, else `git clone --depth 1 --branch ${FESS_THEMES_REF}`), validating `theme.yml`; seed `system.properties.template` → live `system.properties` only if absent, rewriting `theme.default=${THEME_NAME}`; render `config/clip.yaml` from `CLIP_MODEL_NAME`; `rm -f` stale plugin jars; chown bind mounts to container UIDs (fess=1001, opensearch/clip=1000) on Linux. Drop the old jar-download and the leftover `WEB-INF/view/semantic` handling. `bin/git_pull.sh` is removed (git-ignored live file + tracked template replaces it).

### 7.5 Demo content and crawl

`bin/fetch-sample-images.sh` populates `./data/content` with a small CC0 image set (plus a few HTML pages and a PDF) served by `nginx`. The README documents (and, if reliable, an init step performs) a **web crawl of `http://content/`** followed by the reindex, so thumbnails generate and the lightbox has full-size originals. Exact crawl-vs-reindex ordering and whether to fully automate the crawl (vs. a one-command documented step) will be settled during implementation and verified in-browser.

### 7.6 `system.properties.template` (tracked; live file git-ignored)

`theme.default=mosaic`, `thumbnail.enabled=true`, suggest on, `login.required=false`, purge retention (90-day). `.gitignore` extended to ignore live runtime data while tracking the template.

### 7.7 `compose-production.yaml`, README

Production overlay: `https-portal` TLS proxy (`DOMAIN` → `fess01:8080`), prod heap. README fully rewritten: architecture diagram, getting started, crawl-and-search walkthrough, **the `-noble` thumbnail-tooling note** (why the default Alpine image would show broken image tiles), model swap (multilingual ↔ max-quality) + reindex caveat, production/TLS, troubleshooting. The broken FiftyOne mount is replaced by the `content`/nginx approach (FiftyOne kept as an optional larger dataset).

## 8. Non-goals / deferred

- **Search-by-image (image upload → find similar):** deferred. The building block (`CasClient.getImageEmbedding`) exists, but wiring it into search needs a new plugin Action + locally-built jar; out of scope to keep construction clean. The theme ships a hidden, feature-detected affordance.
- **Custom SigLIP 2 embedding server:** documented as a future "quality-max / GPU-host" option; not built.
- **Higher-resolution generated thumbnails:** Fess's command thumbnail generators are hardcoded to 100×100. For image hits the theme uses full-resolution `url_link`, so this mostly affects non-image tiles. An optional bind-mounted higher-res `generate-thumbnail` script is noted as a possible enhancement but not required.
- **`fess-webapp-multimodal` changes of any kind.**

## 9. Testing & verification

- **Theme contracts:** `theme.yml` fields; `index.html` contains all required `BundledBootstrapThemeTest` markers; i18n exact key-set parity across 16 locales; `package.sh` produces a valid zip.
- **End-to-end (Claude in Chrome on the real stack, `docker compose up -d`):** thumbnails actually render on `-noble`; masonry gallery + lazy-load + 404-retry; lightbox full-size + metadata; **hybrid mixed results** (image + text docs); a **Japanese query returns relevant images** (multilingual model); searcher badges (Keyword/Visual/Blend); fallback tiles for thumbnail-less docs; suggest, facets, pagination, list toggle; responsive/mobile offcanvas; `prefers-reduced-motion`; CSP has no console violations.
- **Stack:** `up -d` reaches a working state with no manual steps; `init-fess-index` makes the mapping carry `content_vector`; restart preserves thumbnails.

## 10. Delivery

- **`fess-themes`** — branch, add `themes/mosaic/` (+ root README row), package. Own PR.
- **`docker-multimodalsearch`** — branch `feature/fess-15.7-multimodal-gallery` (created), modernize per §7, consume the theme. Own PR.
- Each with a committed design/plan doc under `docs/superpowers/`. Sub-agents per task (theme authoring, compose/scripts, README, verification). Branch + `gh` HTTPS push. **No internal/confidential info and no claude.ai links** in commit messages or PR text.

## 11. Risks and mitigations

- **Thumbnail tooling / async timing** — mitigated by `-noble` (tooling present) + the theme's 404-retry/backoff + placeholder; the reindex init and the every-minute thumbnail job mean a short warm-up before all tiles fill.
- **Model download size / first-boot latency** (~1.6 GB for the default model) — cached in `./data/clip_server/cache`; documented; the smaller/English model remains a `.env` swap.
- **CSP `img-src` widening** — a conscious, documented trade-off inherent to a visual-search UI; all other directives stay strict.
- **Cross-repo coordination** — `.env` `FESS_THEMES_REF` pins the theme source; the theme can be developed against a local `FESS_THEMES_DIR` before the `fess-themes` PR merges.
- **`.api.` response-field property in the exact 15.7 build** — verify the `query.additional.api.response.fields` key exists in the deployed 15.7 image during implementation; badges degrade gracefully if absent.
