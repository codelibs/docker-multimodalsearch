# docker-multimodalsearch Modernization + `mosaic` Gallery Theme — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize the `docker-multimodalsearch` demo to Fess 15.7 / OpenSearch 3.7 with `.env`-driven, thumbnail-capable, hybrid-multimodal config, and ship a new `mosaic` Fess StaticTheme (in `fess-themes`) that renders results as a thumbnail-first visual gallery.

**Architecture:** Two repositories. `fess-themes/themes/mosaic` is a self-contained SPA StaticTheme, ported from `themes/semanticlens`, whose signature UX is a masonry gallery of Fess thumbnails with a lightbox and Keyword/Visual/Blend provenance badges. `docker-multimodalsearch` composes stock GHCR images (Fess `15.7.0-noble`, `fess-opensearch:3.7.0`, `jinaai/clip-server`, `nginx:alpine`) with `.env`, healthchecks, `depends_on` ordering, an `init-fess-index` reindex container, and a `bin/setup.sh` that syncs the theme from `fess-themes`. The Fess `fess-webapp-multimodal:15.7.0` plugin is used unmodified via `FESS_PLUGINS`.

**Tech Stack:** Docker Compose, GHCR Fess/OpenSearch images, Jina clip-server (open_clip multilingual CLIP), OpenSearch KNN (lucene/hnsw/cosinesimil), vanilla-JS SPA on Fess `/api/v2/*`, POSIX `sh`/`bash` scripts, `yq`/`jq`/`curl`.

## Global Constraints

Copied verbatim from the spec; every task's requirements implicitly include these.

- **Fess image:** `ghcr.io/codelibs/fess:15.7.0-noble` (NOT the default Alpine — only `-noble` renders image/PDF/Office thumbnails). Parameterized via `.env`.
- **OpenSearch image:** `ghcr.io/codelibs/fess-opensearch:3.7.0`; roles `cluster_manager,data,ingest,ml`; publish `127.0.0.1:9200:9200` (loopback only).
- **Plugin:** `fess-webapp-multimodal:15.7.0` via `FESS_PLUGINS` env. No local jar. `fess-webapp-multimodal` source is NOT modified.
- **Ranking:** hybrid — `rank.fusion.searchers` left UNSET (`default` + `multi_modal`).
- **Searcher field prop:** `-Dfess.config.query.additional.api.response.fields=searcher` (the `.api.` variant — NOT `query.additional.response.fields`).
- **Default CLIP model:** `xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k` (512-dim, multilingual; note hyphens in `laion5b-s13b-b90k`). Dimension stays `512`. Model name + dimension parameterized and kept in lockstep.
- **Multimodal `-D` props:** `fess.multimodal.content.field=content_vector`, `content.dimension=${MULTIMODAL_DIMENSION}` (512), `content.method=hnsw`, `content.engine=lucene`, `content.space_type=cosinesimil`, `min_score=${CLIP_MIN_SCORE}`; `clip.server.endpoint=http://clip_server:51000`.
- **Theme name:** `mosaic`. Authored in `fess-themes/themes/mosaic`, synced into the stack (never committed to `docker-multimodalsearch`).
- **Theme thumbnail tile source:** `GET /thumbnail/?docId=<doc_id>&queryId=<query_id>` (`query_id` from `env.query_id`, required); lazy-load + 404-retry-with-backoff; gate on config `thumbnailEnabled` AND non-empty per-hit `thumbnail`.
- **Theme CSP:** `img-src 'self' data: https: http:` (widened for crawled imagery); all other directives strict (`script-src 'self'`, `font-src 'self'`, `connect-src 'self'`, `frame-src blob:`, `child-src blob:`, `base-uri 'self'`). No inline JS, no web fonts.
- **Theme contracts:** valid `theme.yml`; `index.html` contains all `BundledBootstrapThemeTest` markers; i18n exact key-set parity across all 16 locales; `scripts/package.sh mosaic` produces a valid zip with `theme.yml` at root.
- **Commit/PR hygiene:** no internal/confidential info and NO `claude.ai` / session links in any commit message or PR text. Commit frequently.
- **No `fess-webapp-multimodal` changes; search-by-image deferred** (theme ships a hidden, feature-detected image-drop affordance only).

---

## File Structure

### Repo A — `fess-themes` (new theme; ported from `themes/semanticlens`)

```
themes/mosaic/
  theme.yml                 # manifest: name mosaic, displayName "Mosaic", minFessVersion 15.7
  index.html                # SPA shell; CSP img-src widened; gallery/lightbox markup; asset paths /themes/mosaic/
  thumbnail.png             # admin preview (placeholder initially)
  README.md                 # theme docs (incl. CSP-widening rationale, searcher badges, thumbnail behavior)
  DESIGN.md                 # design rationale (concept, palette, gallery/lightbox/hero)
  assets/
    app.js                  # entry/router/bootstrap  (ported, path renames only)
    api.js                  # /api/v2 client          (ported, unchanged logic)
    search.js               # GALLERY logic: tiles, thumbnail-retry, fallback card, badge map, lightbox, list toggle (heavily edited)
    home-hero.js            # multimodal hero: converging text/image motif + typewriter (rewritten from semanticlens hero)
    styles.css              # visual identity: gallery grid, tiles, lightbox, badges, hero, palette tokens (heavily edited)
    i18n.js router.js auth.js chat.js cache.js advance.js profile.js help.js error.js format.js markdown.js compat.js  (ported, path renames only)
    logo.png logo-head.png  # placeholders (as in semanticlens)
  i18n/messages.<16 locales>.json   # +mosaic keys (gallery/lightbox/searcher/hero); exact key-set parity
  help/<8 locales>.json             # ported

README.md                   # root: add one table row for `mosaic`
```

### Repo B — `docker-multimodalsearch` (modernization)

```
.env.example                # NEW: all tunables
.gitignore                  # EDIT: ignore runtime data, keep templates
compose.yaml                # REWRITE: search01, clip_server, content(nginx), fess01, init-fess-index
compose-production.yaml     # REWRITE: https-portal TLS overlay + prod heap
config/clip.yaml            # becomes config/clip.yaml.template (model injected by setup.sh)
data/fess/opt/fess/system.properties.template   # NEW (tracked); live file git-ignored
data/https-portal/conf/multimodal.codelibs.org.ssl.conf.erb   # NEW (prod vhost)
bin/setup.sh                # REWRITE: theme sync, clip.yaml render, seed template, cleanup, chown
bin/init-fess-index.sh      # NEW: automate reindex (runs in init-fess-index container)
bin/fetch-sample-images.sh  # NEW: populate ./data/content with a small CC0 set + a few HTML/PDF
bin/git_pull.sh             # DELETE
README.md                   # REWRITE
docs/superpowers/…          # spec + this plan (already committed)
```

---

# PART A — `mosaic` theme (`fess-themes`)

> Work in the `fess-themes` repo. Create branch `feature/mosaic-theme` first. Base = `themes/semanticlens` (the closest sibling). Guiding memory: **port, don't blind-copy** — keep structure, change identity + gallery behavior.
>
> **TDD adaptation:** there is no JS unit harness in `fess-themes`. Each task's "verify" step is a concrete contract/behavior check (grep/`yq`/node one-liners, or a browser check deferred to Part C). Write the check, run it to see it fail, make it pass.

### Task A1: Scaffold `mosaic` from `semanticlens`

**Files:**
- Create: `themes/mosaic/**` (copy of `themes/semanticlens/**`)
- Modify: `themes/mosaic/theme.yml`, all `themes/mosaic/index.html` + `assets/*` path references
- Modify (root): `README.md` (add a `mosaic` row)

**Interfaces:**
- Produces: a valid StaticTheme named `mosaic` served at `/themes/mosaic/`, identical in behavior to `semanticlens` (baseline before gallery edits). All later Part-A tasks edit files inside `themes/mosaic/`.

- [ ] **Step 1: Branch + copy the base**
```bash
cd <fess-themes>
git checkout -b feature/mosaic-theme
cp -R themes/semanticlens themes/mosaic
```

- [ ] **Step 2: Rename every `/themes/semanticlens/` path reference to `/themes/mosaic/`**
```bash
cd themes/mosaic
grep -rl "/themes/semanticlens/" . | xargs sed -i '' 's#/themes/semanticlens/#/themes/mosaic/#g'   # macOS sed; use `sed -i` on GNU
```

- [ ] **Step 3: Rewrite `theme.yml` identity**

`themes/mosaic/theme.yml`:
```yaml
apiVersion: fess.codelibs.org/v1
kind: StaticTheme
name: mosaic
displayName: "Mosaic"
version: "1.0.0"
minFessVersion: "15.7"
supportedLocales: [en, ja, de, es, fr, ko, pt-BR, zh-CN]
entry: index.html
spaFallback: true
type: static
thumbnail: thumbnail.png
```

- [ ] **Step 4: Replace README.md / DESIGN.md headers** with `mosaic` identity (full content authored in Task A9/DESIGN; for now replace the title lines and the "SemanticLens"→"Mosaic" / "semanticlens"→"mosaic" occurrences).
```bash
grep -rl -i "semanticlens" themes/mosaic | xargs sed -i '' 's/SemanticLens/Mosaic/g; s/semanticlens/mosaic/g'
```

- [ ] **Step 5: Verify manifest + no stale references (this is the test)**
```bash
cd <fess-themes>
yq '.name, .kind, .entry, .spaFallback' themes/mosaic/theme.yml     # expect: mosaic / StaticTheme / index.html / true
grep -rn "semanticlens" themes/mosaic || echo "OK: no stale semanticlens references"
```
Expected: manifest prints the four values; grep prints "OK: no stale semanticlens references".

- [ ] **Step 6: Verify it packages**
```bash
./scripts/package.sh mosaic
unzip -l dist/mosaic-1.0.0.zip | grep -q "theme.yml" && echo "OK: theme.yml at zip root"
```
Expected: "OK: theme.yml at zip root".

- [ ] **Step 7: Add the root README row**

In `README.md`'s themes table, add a row: `| mosaic | Mosaic | Thumbnail-first visual gallery for multimodal (image + text) search | 15.7 |` (match the table's exact column order).

- [ ] **Step 8: Commit**
```bash
git add themes/mosaic README.md
git commit -m "feat(mosaic): scaffold mosaic theme from semanticlens base"
```

---

### Task A2: Gallery results — thumbnail tiles, retry, fallback, badge

**Files:**
- Modify: `themes/mosaic/assets/search.js` (result rendering)
- Modify: `themes/mosaic/index.html` (results container markup, if a grid container id is needed)
- Modify: `themes/mosaic/assets/styles.css` (grid + tile classes — minimal here; full styling in A7)

**Interfaces:**
- Consumes (from `api.js`, unchanged): `api.get('/search', params)` → envelope with `env.data[]`, `env.record_count`, `env.query_id`; `api.getConfig()` → `{ thumbnailEnabled, filetype_options, facet_views, features }`.
- Produces (used by A3 lightbox, A4 toggle): `buildGalleryTile(doc, queryId, rank)` → `<li class="tile">`; `state.viewMode` ∈ `{grid,list}`; `state.currentEnv` (last search envelope) for the lightbox; `searcherBadgeKind(doc)` → `keyword|visual|blend|null`.

- [ ] **Step 1: Replace the semanticlens searcher-badge mapping with multimodal semantics**

In `search.js`, replace the badge-kind logic so `default`→`keyword`, `multi_modal`→`visual`, both→`blend`:
```js
// searcher may be an array or comma-string of searcher names
function searcherKinds(doc) {
  const raw = doc && doc.searcher;
  const list = Array.isArray(raw) ? raw : (typeof raw === 'string' ? raw.split(',') : []);
  return new Set(list.map(s => String(s).trim().toLowerCase()).filter(Boolean));
}
function searcherBadgeKind(doc) {
  const k = searcherKinds(doc);
  if (k.size === 0) return null;                 // field absent → no badge (graceful degradation)
  const kw = k.has('default'), vi = k.has('multi_modal');
  if (kw && vi) return 'blend';
  if (vi) return 'visual';
  if (kw) return 'keyword';
  return 'other';
}
```

- [ ] **Step 2: Implement the thumbnail tile with lazy-load + async 404 retry**

Add to `search.js`. The tile image src is the same-origin endpoint; retry on error because generation is async.
```js
const THUMB_RETRY_MS = [2000, 5000, 15000, 30000];  // backoff, ~1 job cycle cap
function thumbUrl(docId, queryId) {
  return `/thumbnail/?docId=${encodeURIComponent(docId)}&queryId=${encodeURIComponent(queryId)}`;
}
function attachThumb(imgEl, docId, queryId) {
  let attempt = 0;
  const load = () => { imgEl.src = thumbUrl(docId, queryId) + (attempt ? `&_r=${attempt}` : ''); };
  imgEl.addEventListener('error', () => {
    if (attempt >= THUMB_RETRY_MS.length) { imgEl.closest('.tile')?.classList.add('tile--noimg'); return; }
    const delay = THUMB_RETRY_MS[attempt++];
    setTimeout(load, delay);
  });
  // lazy: only start loading when near viewport
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((es, obs) => es.forEach(e => { if (e.isIntersecting) { load(); obs.disconnect(); } }));
    io.observe(imgEl);
  } else { load(); }
}
```

- [ ] **Step 3: Implement `buildGalleryTile` (thumbnail tile OR typed fallback card)**

```js
const FILETYPE_ICON = { html:'fa-globe', pdf:'fa-file-pdf-o', word:'fa-file-word-o', excel:'fa-file-excel-o',
  powerpoint:'fa-file-powerpoint-o', image:'fa-file-image-o', txt:'fa-file-text-o', others:'fa-file-o' };
function buildGalleryTile(doc, queryId, rank) {
  const li = document.createElement('li');
  li.className = 'tile';
  li.dataset.docId = doc.doc_id;
  li.dataset.rank = String(rank);
  const kind = searcherBadgeKind(doc);
  if (kind) li.classList.add(`tile--${kind}`);
  const cfgThumb = (window.__mosaicThumbEnabled === true);
  if (cfgThumb && doc.thumbnail) {
    const img = document.createElement('img');
    img.className = 'tile__img'; img.loading = 'lazy'; img.alt = doc.content_title || '';
    li.appendChild(img);
    attachThumb(img, doc.doc_id, queryId);
  } else {
    li.classList.add('tile--noimg');
    const icon = document.createElement('i');
    icon.className = `fa ${FILETYPE_ICON[doc.filetype] || FILETYPE_ICON.others} tile__icon`;
    icon.setAttribute('aria-hidden', 'true');
    li.appendChild(icon);
  }
  // caption (title + site) — always present, XSS-safe
  const cap = document.createElement('div'); cap.className = 'tile__cap';
  const t = document.createElement('span'); t.className = 'tile__title'; t.textContent = doc.content_title || doc.filename || doc.url_link || '';
  cap.appendChild(t);
  if (kind) { const b = buildSearcherBadge(kind); if (b) li.appendChild(b); }
  li.appendChild(cap);
  li.tabIndex = 0;                       // keyboard focusable → opens lightbox (A3)
  return li;
}
```
Also add `buildSearcherBadge(kind)` → a `<span class="badge badge--{kind}"><i aria-hidden></i><span>{i18n searcher.{kind}}</span></span>` (icon + text, never color alone). Set `window.__mosaicThumbEnabled = !!cfg.thumbnailEnabled` where the config is loaded.

- [ ] **Step 4: Replace `renderResults` to emit the gallery grid**

Point `renderResults(env)` at the results container as a `<ul class="gallery">` (grid) when `state.viewMode==='grid'`, calling `buildGalleryTile(doc, env.query_id, i)` per hit; keep the semanticlens list renderer for `list` mode (A4). Store `state.currentEnv = env`.

- [ ] **Step 5: Verify (static behavior check)**

Node smoke test of the pure functions (no DOM): extract `searcherBadgeKind` logic into a quick check.
```bash
node -e '
function kinds(d){const r=d.searcher;const l=Array.isArray(r)?r:(typeof r==="string"?r.split(","):[]);return new Set(l.map(s=>s.trim().toLowerCase()).filter(Boolean));}
function k(d){const s=kinds(d);if(!s.size)return null;const kw=s.has("default"),vi=s.has("multi_modal");if(kw&&vi)return "blend";if(vi)return "visual";if(kw)return "keyword";return "other";}
console.assert(k({searcher:["multi_modal"]})==="visual","visual");
console.assert(k({searcher:"default,multi_modal"})==="blend","blend");
console.assert(k({searcher:["default"]})==="keyword","keyword");
console.assert(k({})===null,"none");
console.log("OK badge mapping");'
```
Expected: `OK badge mapping` (no assertion output). Full visual verification is deferred to Part C.

- [ ] **Step 6: Commit**
```bash
git add themes/mosaic/assets/search.js themes/mosaic/index.html themes/mosaic/assets/styles.css
git commit -m "feat(mosaic): gallery tiles with thumbnail retry, fallback card, searcher badge"
```

---

### Task A3: Lightbox

**Files:**
- Modify: `themes/mosaic/index.html` (add a lightbox overlay container — hidden by default)
- Modify: `themes/mosaic/assets/search.js` (open/close/navigate)
- Modify: `themes/mosaic/assets/styles.css` (overlay styles — minimal here; full in A7)

**Interfaces:**
- Consumes: `state.currentEnv.data[]`, `buildGoUrl`/`safeHref` (from `format.js`, ported), `searcherBadgeKind`.
- Produces: `openLightbox(rank)`, `closeLightbox()`, `lightboxNext()/Prev()`.

- [ ] **Step 1: Add the overlay markup to `index.html`**

Inside `#results-view`, add (hidden):
```html
<div id="lightbox" class="lightbox" hidden role="dialog" aria-modal="true" aria-label="Result preview">
  <button class="lightbox__close" data-lb="close" aria-label="Close">&times;</button>
  <button class="lightbox__nav lightbox__prev" data-lb="prev" aria-label="Previous">&#8249;</button>
  <figure class="lightbox__figure">
    <img class="lightbox__img" alt="">
    <figcaption class="lightbox__meta"></figcaption>
  </figure>
  <button class="lightbox__nav lightbox__next" data-lb="next" aria-label="Next">&#8250;</button>
</div>
```

- [ ] **Step 2: Implement open/close/navigate with focus trap + keyboard**

In `search.js`:
```js
function openLightbox(rank) {
  const env = state.currentEnv; if (!env) return;
  const doc = env.data[rank]; if (!doc) return;
  state.lbRank = rank;
  const lb = document.getElementById('lightbox');
  const img = lb.querySelector('.lightbox__img');
  const isImage = (doc.mimetype || '').startsWith('image/');
  img.src = isImage && (doc.url_link || doc.url) ? (doc.url_link || doc.url)
          : thumbUrl(doc.doc_id, env.query_id);          // full-res for images, thumb otherwise
  img.alt = doc.content_title || '';
  lb.querySelector('.lightbox__meta').replaceChildren(buildLightboxMeta(doc));  // title, url_link, mimetype, size, date, score, badge, actions
  lb.hidden = false; state.lbPrevFocus = document.activeElement;
  lb.querySelector('.lightbox__close').focus();
}
function closeLightbox() { const lb = document.getElementById('lightbox'); lb.hidden = true; state.lbPrevFocus?.focus?.(); }
function lightboxNext() { const n = state.lbRank + 1; if (state.currentEnv?.data[n]) openLightbox(n); }
function lightboxPrev() { const n = state.lbRank - 1; if (n >= 0) openLightbox(n); }
```
Wire: click/Enter on a `.tile` → `openLightbox(+tile.dataset.rank)`; delegate clicks on `[data-lb]`; keydown Esc→close, ArrowRight→next, ArrowLeft→prev; trap Tab within the overlay while open. `buildLightboxMeta(doc)` builds a metadata `<div>` (XSS-safe `textContent`; `url_link` via `safeHref`, opened `target="_blank" rel="noopener"`; Cache link if `doc.has_cache`).

- [ ] **Step 3: Verify (markup contract)**
```bash
grep -q 'id="lightbox"' themes/mosaic/index.html && grep -q 'aria-modal="true"' themes/mosaic/index.html && echo "OK lightbox markup"
```
Expected: `OK lightbox markup`. Behavior verified in Part C.

- [ ] **Step 4: Commit**
```bash
git add themes/mosaic/index.html themes/mosaic/assets/search.js themes/mosaic/assets/styles.css
git commit -m "feat(mosaic): lightbox with full-res image, metadata, keyboard nav"
```

---

### Task A4: Grid/list view toggle

**Files:** Modify `themes/mosaic/index.html` (toggle control near results header), `themes/mosaic/assets/search.js` (view switch), `themes/mosaic/assets/styles.css`.

**Interfaces:** Consumes `state.currentEnv`; produces `setViewMode('grid'|'list')` persisted in `localStorage('mosaic.view')`.

- [ ] **Step 1:** Add a toggle to `index.html` results header: two buttons `data-view="grid"` / `data-view="list"` with `aria-pressed`.
- [ ] **Step 2:** Implement `setViewMode(mode)` → toggles a `results--list`/`results--grid` class on the container, persists to `localStorage`, re-renders `state.currentEnv`. On load, read the stored mode (default `grid`). The `list` renderer is the ported semanticlens result-list card.
- [ ] **Step 3: Verify**
```bash
grep -q 'data-view="grid"' themes/mosaic/index.html && grep -q 'data-view="list"' themes/mosaic/index.html && echo "OK toggle markup"
```
- [ ] **Step 4: Commit** `git commit -m "feat(mosaic): grid/list view toggle"`

---

### Task A5: Home hero (multimodal motif + typewriter)

**Files:** Rewrite `themes/mosaic/assets/home-hero.js`; modify `themes/mosaic/index.html` (`#home-view` hero markup); modify `themes/mosaic/assets/styles.css`.

**Interfaces:** Consumes the real `#contentQuery` input, i18n keys `home.hero_*`, `home.example_1..4`; produces `homeHero.setActive(bool)` called from `showView()` (already wired in semanticlens `app.js`).

- [ ] **Step 1:** Rewrite `home-hero.js` around a multimodal concept: a canvas with a stream of small "text tokens" flowing from the left and "image tiles" (colored rounded rects) from the right, converging toward a central "shared embedding" node; a typewriter cycling four localized visual example queries as the `#contentQuery` **placeholder attribute only** (never `.value`), yielding when the user types. Reuse the semanticlens rAF gating: single static frame + static placeholder under `prefers-reduced-motion`; `active && !document.hidden`; pause on `visibilitychange` and when leaving `#home-view`; all decorative nodes `aria-hidden`.
- [ ] **Step 2:** Replace `#home-view` hero markup: headline/subline, the glowing search pill wrapping `#contentQuery`, three preview cards (Keyword / Visual / Blend), `<canvas id="mosaic-hero-canvas" aria-hidden="true">`. Keep `#home-popular-words` hidden (as semanticlens).
- [ ] **Step 3: Verify**
```bash
grep -q 'id="mosaic-hero-canvas"' themes/mosaic/index.html && grep -q 'setActive' themes/mosaic/assets/home-hero.js && echo "OK hero wired"
node -e 'require("fs").readFileSync("themes/mosaic/assets/home-hero.js","utf8").includes("prefers-reduced-motion")||process.exit(1);console.log("OK reduced-motion honored")'
```
- [ ] **Step 4: Commit** `git commit -m "feat(mosaic): multimodal home hero with typewriter"`

---

### Task A6: Filter rail + optional composition summary

**Files:** Modify `themes/mosaic/assets/search.js` (the ported count-free sidebar + a small composition line), `themes/mosaic/index.html`, `themes/mosaic/assets/styles.css`.

**Interfaces:** Consumes `api.getConfig()` → `filetype_options`, `facet_views`; `env.facet_field` (label), `env.data[].searcher`.

- [ ] **Step 1:** Keep semanticlens's count-free sidebar (File type / Updated / Size from `/api/v2/ui/config`) and label facet from `env.facet_field`. Update labels/captions to mosaic wording. Ensure `state.facetQueries`/`fields`/`sdh` are cleared in `runFromUrl()` before re-hydrating (stale-facet contract).
- [ ] **Step 2:** Add a compact composition line above the gallery: `aria-live="polite"`, "N results · mostly visual / balanced / mostly keyword", derived from the page's `searcher` mix (threshold 60%); hidden when no hit carries `searcher`.
- [ ] **Step 3: Verify** grep for the composition container id and the sidebar group ids; run the stale-facet reset check:
```bash
grep -q 'aria-live="polite"' themes/mosaic/index.html && echo "OK composition line"
grep -q 'facetQueries' themes/mosaic/assets/search.js && echo "OK facet state present"
```
- [ ] **Step 4: Commit** `git commit -m "feat(mosaic): count-free filter rail + composition summary"`

---

### Task A7: Visual identity (`styles.css`) + CSP

**Files:** Modify `themes/mosaic/assets/styles.css` (palette tokens, gallery grid, tiles, badges, lightbox, hero, responsive, reduced-motion); modify `themes/mosaic/index.html` CSP meta.

- [ ] **Step 1:** Set `:root` palette tokens — a neutral, low-chroma surface (let thumbnails carry color), one interactive accent, and three source-of-match hues with base/subtle/text triples: `--mm-keyword` (amber), `--mm-visual` (violet/magenta), `--mm-blend` (teal). System-font stack (no web fonts).
- [ ] **Step 2:** Implement the masonry/grid gallery (`.gallery` → CSS grid with `grid-template-columns: repeat(auto-fill, minmax(160px,1fr))` and CSS `columns`-based masonry fallback), square `.tile__img` with `object-fit: cover`, `.tile--noimg` centered icon card, corner `.badge--{kind}`, `.lightbox` fullscreen overlay, hero styles, responsive breakpoints (facet rail → offcanvas < 768px), and `@media (prefers-reduced-motion: reduce)` freezes.
- [ ] **Step 3:** Set the CSP meta in `index.html` exactly (widened `img-src` only):
```html
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data: https: http:; connect-src 'self'; frame-src blob:; child-src blob:; base-uri 'self'">
```
- [ ] **Step 4: Verify (CSP + markers preserved)**
```bash
grep -q "img-src 'self' data: https: http:" themes/mosaic/index.html && echo "OK csp img-src widened"
for m in 'frame-src blob:' 'child-src blob:' 'id="suggest-dropdown"' 'id="home-suggest-dropdown"' 'data-bs-toggle="offcanvas"' 'id="searchOptions"'; do grep -q "$m" themes/mosaic/index.html || echo "MISSING: $m"; done; echo "marker check done"
grep -q 'rel="search"' themes/mosaic/index.html && echo "FAIL: rel=search present" || echo "OK no rel=search"
```
Expected: csp OK; "marker check done" with no MISSING lines; "OK no rel=search".
- [ ] **Step 5: Commit** `git commit -m "feat(mosaic): gallery visual identity and CSP"`

---

### Task A8: i18n — mosaic keys across 16 locales, key-parity

**Files:** Modify `themes/mosaic/i18n/messages.<locale>.json` (all 16).

**Interfaces:** New namespaces used by A2–A6: `searcher.keyword/visual/blend/other`, `gallery.grid/list`, `lightbox.open_original/cache/close/next/prev`, `composition.mostly_visual/mostly_keyword/balanced/total`, `home.hero_title/hero_sub/example_1..4/match_keyword/match_visual/match_blend`.

- [ ] **Step 1:** In `messages.en.json`, add all new mosaic keys (replace the semanticlens `searcher.*`/`composition.*`/`home.*` copy with multimodal wording; keep every other inherited key). In `messages.ja.json`, add proper Japanese for all new keys.
- [ ] **Step 2:** For the remaining 14 locales, add the same keys (translated where feasible; English fallback acceptable but keys MUST exist for parity). Remove any semanticlens-only keys that no longer appear in `en` so the sets stay equal.
- [ ] **Step 3: Verify exact key-set parity across all 16 locales (the test)**
```bash
node -e '
const fs=require("fs"),dir="themes/mosaic/i18n";
const files=fs.readdirSync(dir).filter(f=>f.startsWith("messages.")&&f.endsWith(".json"));
const keys=f=>{const o=JSON.parse(fs.readFileSync(`${dir}/${f}`));const out=[];(function w(p,x){for(const k in x){const q=p?p+"."+k:k;typeof x[k]==="object"&&x[k]?w(q,x[k]):out.push(q);}})("",o);return out.sort();};
const en=JSON.stringify(keys("messages.en.json"));let ok=true;
for(const f of files){if(JSON.stringify(keys(f))!==en){ok=false;console.log("KEY MISMATCH:",f);}}
console.log(files.length+" locales; parity "+(ok?"OK":"FAILED"));
if(!ok)process.exit(1);'
```
Expected: `16 locales; parity OK`.
- [ ] **Step 4: Commit** `git commit -m "feat(mosaic): i18n keys for gallery/lightbox/searcher/hero with 16-locale parity"`

---

### Task A9: Docs, assets, package + full contract check

**Files:** `themes/mosaic/README.md`, `themes/mosaic/DESIGN.md`, `themes/mosaic/thumbnail.png`, `themes/mosaic/assets/logo*.png`, `themes/mosaic/help/*`.

- [ ] **Step 1:** Write `DESIGN.md` (concept, palette, gallery/lightbox/hero, searcher badges, thumbnail-endpoint behavior + retry, CSP-widening rationale) and `README.md` (install/activate, features, the `img-src` note, the `query.additional.api.response.fields=searcher` requirement for badges, graceful degradation). Port `help/*` copy to mosaic wording.
- [ ] **Step 2:** Provide a placeholder `thumbnail.png` (a simple gallery-grid graphic ≤512×512, ≤512KB) and keep `logo*.png` placeholders (branding art is a follow-up, as in semanticlens). Note the follow-up in README.
- [ ] **Step 3: Full contract check + package**
```bash
cd <fess-themes>
yq -e '.apiVersion=="fess.codelibs.org/v1" and .kind=="StaticTheme" and .name=="mosaic" and .entry=="index.html" and .spaFallback==true' themes/mosaic/theme.yml
for a in app.js api.js i18n.js auth.js search.js chat.js styles.css; do test -f themes/mosaic/assets/$a || echo "MISSING asset $a"; done
test -f themes/mosaic/i18n/messages.en.json && test -f themes/mosaic/i18n/messages.ja.json && echo "OK required bundles"
./scripts/package.sh mosaic && unzip -l dist/mosaic-1.0.0.zip | grep -q "theme.yml" && echo "OK packaged"
```
Expected: yq exits 0; no MISSING lines; "OK required bundles"; "OK packaged".
- [ ] **Step 4: Commit** `git commit -m "docs(mosaic): design/readme/help, thumbnail, package verification"`

---

# PART B — `docker-multimodalsearch` modernization

> Work in `docker-multimodalsearch` on the existing `feature/fess-15.7-multimodal-gallery` branch. All service/version/prop values are fixed by **Global Constraints**.

### Task B1: `.env.example` + `.gitignore`

**Files:** Create `.env.example`; modify `.gitignore`.

- [ ] **Step 1:** Write `.env.example`:
```dotenv
# Images
FESS_IMAGE=ghcr.io/codelibs/fess:15.7.0-noble
OPENSEARCH_IMAGE=ghcr.io/codelibs/fess-opensearch:3.7.0
NGINX_IMAGE=nginx:alpine
ALPINE_IMAGE=alpine:3.21

# Plugin
FESS_PLUGINS=fess-webapp-multimodal:15.7.0

# CLIP model (keep MODEL and DIMENSION in lockstep)
CLIP_MODEL_NAME=xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k
MULTIMODAL_DIMENSION=512
CLIP_MIN_SCORE=0.5

# Theme
THEME_NAME=mosaic
FESS_THEMES_REPO=https://github.com/codelibs/fess-themes.git
FESS_THEMES_REF=main
# FESS_THEMES_DIR=/absolute/path/to/local/fess-themes   # dev: use a local checkout instead of cloning

# Resources
FESS_HEAP=1g
OPENSEARCH_HEAP=1g
OPENSEARCH_HEAP_PROD=3g

# Ops
FESS_ADMIN_PASSWORD=admin
MAX_WAIT=900
DOMAIN=multimodal.codelibs.org
```

- [ ] **Step 2:** Rewrite `.gitignore` to ignore runtime data and the live system.properties while tracking the template and content dir structure:
```gitignore
/.env
/data/https-portal/ssl_certs
/data/opensearch/usr/share/opensearch/data
/data/opensearch/usr/share/opensearch/config/dictionary
/data/fess/var/lib/fess
/data/fess/var/log/fess
/data/fess/usr/share/fess/app/WEB-INF/plugin
/data/fess/usr/share/fess/app/themes
/data/fess/opt/fess/system.properties
/data/content/*
!/data/content/.gitkeep
/dist
```

- [ ] **Step 3: Verify**
```bash
grep -q "15.7.0-noble" .env.example && grep -q "laion5b-s13b-b90k" .env.example && grep -q "THEME_NAME=mosaic" .env.example && echo "OK env"
git check-ignore -q data/fess/opt/fess/system.properties && echo "OK live props ignored"
```
- [ ] **Step 4: Commit** `git add .env.example .gitignore && git commit -m "feat: add .env.example and runtime .gitignore"`

---

### Task B2: `config/clip.yaml.template` (model injection)

**Files:** Rename `config/clip.yaml` → `config/clip.yaml.template`; the live `config/clip.yaml` is rendered by `setup.sh` (Task B6) and git-ignored via the pattern (add `config/clip.yaml` to `.gitignore` too).

- [ ] **Step 1:** Create `config/clip.yaml.template` with a model placeholder:
```yaml
jtype: Flow
with:
  port: 51000
  protocol: http
  cors: true
executors:
  - name: clip_t
    uses:
      jtype: CLIPEncoder
      with:
        name: '__CLIP_MODEL_NAME__'
      metas:
        py_modules:
          - clip_server.executors.clip_torch
```
- [ ] **Step 2:** Add `/config/clip.yaml` to `.gitignore`.
- [ ] **Step 3: Verify** `grep -q "__CLIP_MODEL_NAME__" config/clip.yaml.template && echo OK`
- [ ] **Step 4: Commit** `git add config/clip.yaml.template .gitignore && git rm --cached config/clip.yaml 2>/dev/null; git commit -m "feat: template clip.yaml for env-driven model selection"`

---

### Task B3: `system.properties.template`

**Files:** Create `data/fess/opt/fess/system.properties.template` (tracked).

- [ ] **Step 1:** Seed values (live file rewritten by setup.sh; git-ignored):
```properties
theme.default=mosaic
thumbnail.enabled=true
suggest.search.log.enabled=true
suggest.document.enabled=true
login.required=false
crawler.document.max.site.length=-1
purge.by.bots=
purge.search.log.day=90
```
- [ ] **Step 2: Verify** `grep -q "theme.default=mosaic" data/fess/opt/fess/system.properties.template && grep -q "thumbnail.enabled=true" data/fess/opt/fess/system.properties.template && echo OK`
- [ ] **Step 3: Commit** `git add data/fess/opt/fess/system.properties.template && git commit -m "feat: add tracked system.properties.template (theme + thumbnails)"`

---

### Task B4: `compose.yaml` rewrite

**Files:** Rewrite `compose.yaml`.

**Interfaces:** Produces the shared volume/paths B5–B7 rely on: `./data/content` (nginx docroot + crawl target `http://content/`), `./data/fess/var/lib/fess` (thumbnails under `fess.var.path`), `./data/fess/usr/share/fess/app/themes/${THEME_NAME}` (theme mount).

- [ ] **Step 1:** Write `compose.yaml`. Key requirements (fill exact env from Global Constraints):
  - `search01`: `image: ${OPENSEARCH_IMAGE}`, env incl. `node.roles=cluster_manager,data,ingest,ml`, `DISABLE_SECURITY_PLUGIN=true`, `DISABLE_INSTALL_DEMO_CONFIG=true`, `bootstrap.memory_lock=true`, `OPENSEARCH_JAVA_OPTS=-Xms${OPENSEARCH_HEAP} -Xmx${OPENSEARCH_HEAP}`; ulimits memlock/nofile; `ports: ["127.0.0.1:9200:9200"]`; healthcheck `curl -f http://localhost:9200/_cluster/health || exit 1`.
  - `clip_server`: `image: jinaai/clip-server`, `platform: linux/amd64`, `command: ["/home/cas/clip_config.yaml"]`, mounts `./config/clip.yaml:/home/cas/clip_config.yaml` + `./data/clip_server/cache:/home/cas/.cache`, env `JINA_HIDE_SURVEY=1`; healthcheck against `http://localhost:51000` (a TCP/HTTP GET). GPU `deploy` block present but commented.
  - `content`: `image: ${NGINX_IMAGE}`, mounts `./data/content:/usr/share/nginx/html:ro`; no published port (internal only); healthcheck `wget -q -O /dev/null http://localhost/ || exit 1`.
  - `fess01`: `image: ${FESS_IMAGE}`, `depends_on: {search01: {condition: service_healthy}, clip_server: {condition: service_healthy}, content: {condition: service_healthy}}`, `environment` incl. `SEARCH_ENGINE_HTTP_URL=http://search01:9200`, `FESS_DICTIONARY_PATH=/usr/share/fess/dict`, `FESS_PLUGINS=${FESS_PLUGINS}`, and one `FESS_JAVA_OPTS` block with the full `-D` set from Global Constraints (note `MULTIMODAL_DIMENSION`, `CLIP_MIN_SCORE`, the `.api.` searcher prop, `job.system.property.filter.pattern=fess.multimodal.*|clip.*`, `-Dthumbnail.width=512 -Dthumbnail.height=512`, admin password); `ports: ["8080:8080"]`; volumes: opt/fess, var/lib/fess, var/log/fess, WEB-INF/plugin, and `./data/fess/usr/share/fess/app/themes/${THEME_NAME}:/usr/share/fess/app/themes/${THEME_NAME}`; healthcheck `curl -f http://localhost:8080/api/v2/health || exit 1`.
  - `init-fess-index`: `image: ${ALPINE_IMAGE}`, `depends_on: {fess01: {condition: service_healthy}}`, mounts `./bin/init-fess-index.sh:/init-fess-index.sh:ro`, `entrypoint: ["sh","/init-fess-index.sh"]`, env `FESS_URL=http://fess01:8080`, `FESS_ADMIN_PASSWORD`, `MAX_WAIT`; `restart: "no"`.
  - `networks: {multimodal_net: {driver: bridge}}`.
- [ ] **Step 2: Verify config parses and resolves**
```bash
cp .env.example .env
docker compose config >/dev/null && echo "OK compose valid"
docker compose config | grep -q "15.7.0-noble" && docker compose config | grep -q "query.additional.api.response.fields=searcher" && echo "OK key props resolved"
```
Expected: both OK lines.
- [ ] **Step 3: Commit** `git add compose.yaml && git commit -m "feat: rewrite compose for Fess 15.7-noble, OS 3.7, clip, nginx content, init-index"`

---

### Task B5: `bin/init-fess-index.sh` (automate reindex)

**Files:** Create `bin/init-fess-index.sh`.

- [ ] **Step 1:** Write an idempotent POSIX `sh` script (installs curl+jq via `apk add --no-cache curl jq`) that: waits for `${FESS_URL}/api/v2/health`; short-circuits if the `fess.search` mapping already contains `content_vector` (query `${SEARCH... }` is not reachable — instead check via Fess admin API or the search-engine through fess); logs into `/admin/` via the LastaFlute form flow (GET login page → extract `name="crawlerToken"`/`TRANSACTION_TOKEN` hidden field → POST `/login/`), then POST `/admin/maintenance/start` with `replaceAliases=on` + the transaction token; poll until reindex completes and `content_vector` appears; exit 0. On any unrecoverable error, log and exit non-zero. (Model this on `docker-semanticsearch/bin/setup-fess-index.sh` — read it and adapt: same login/token/reindex mechanics, drop the semantic-specific parts.)
- [ ] **Step 2: Verify (lint + shape)**
```bash
sh -n bin/init-fess-index.sh && echo "OK sh syntax"
grep -q "content_vector" bin/init-fess-index.sh && grep -q "replaceAliases" bin/init-fess-index.sh && echo "OK reindex logic present"
```
- [ ] **Step 3: Commit** `git add bin/init-fess-index.sh && git commit -m "feat: init-fess-index automates the knn-mapping reindex"`

---

### Task B6: `bin/setup.sh` rewrite

**Files:** Rewrite `bin/setup.sh`; delete `bin/git_pull.sh`.

- [ ] **Step 1:** Write `bin/setup.sh` (`set -euo pipefail`) that:
  1. Loads `.env` if present (else copies `.env.example`→`.env` and loads).
  2. Creates bind-mount dirs: opensearch data/dictionary, fess opt/var-lib/var-log/plugin, `themes`, `data/content` (+ `.gitkeep`), `data/clip_server/cache`, `data/https-portal/ssl_certs`.
  3. Renders `config/clip.yaml` from `config/clip.yaml.template` with `sed "s#__CLIP_MODEL_NAME__#${CLIP_MODEL_NAME}#"`.
  4. Seeds live `data/fess/opt/fess/system.properties` from the tracked `.template` only if absent, then `sed` `theme.default=${THEME_NAME}`.
  5. **Syncs the theme:** if `FESS_THEMES_DIR` is set, copy `${FESS_THEMES_DIR}/themes/${THEME_NAME}`; else `git clone --depth 1 --branch ${FESS_THEMES_REF} ${FESS_THEMES_REPO}` to a temp dir and copy `themes/${THEME_NAME}`. Validate `theme.yml` exists; stage to tmp, then `rm -rf` + recopy into `data/fess/usr/share/fess/app/themes/${THEME_NAME}`.
  6. `rm -f` any stale `data/fess/usr/share/fess/app/WEB-INF/plugin/fess-webapp-multimodal-*.jar`.
  7. On Linux only, chown bind mounts to container UIDs (fess=1001, opensearch/clip=1000).
  - Source `docker-semanticsearch/bin/setup.sh` for the theme-sync/seeding idioms. Do NOT download plugin jars.
- [ ] **Step 2:** `git rm bin/git_pull.sh`.
- [ ] **Step 3: Verify**
```bash
sh -n bin/setup.sh && echo "OK sh syntax"
grep -q "FESS_THEMES_DIR" bin/setup.sh && grep -q "clip.yaml.template" bin/setup.sh && grep -q "theme.yml" bin/setup.sh && echo "OK setup logic"
# dry run against a local fess-themes checkout:
FESS_THEMES_DIR=<local-fess-themes> bash bin/setup.sh && test -f data/fess/usr/share/fess/app/themes/mosaic/theme.yml && echo "OK theme synced"
```
Expected: all OK lines; `mosaic/theme.yml` present after sync.
- [ ] **Step 4: Commit** `git add bin/setup.sh && git rm bin/git_pull.sh && git commit -m "feat: rewrite setup.sh (theme sync, clip.yaml render, template seed); drop git_pull.sh"`

---

### Task B7: `bin/fetch-sample-images.sh` + demo content

**Files:** Create `bin/fetch-sample-images.sh`; create `data/content/.gitkeep`.

- [ ] **Step 1:** Write `bin/fetch-sample-images.sh` (`set -euo pipefail`) that downloads a small CC0/public-domain sample set (≈20–40 images across varied subjects) plus 2–3 simple HTML pages (each with an `og:image`) and one small PDF into `./data/content/`, generating a minimal `index.html` listing so the web crawler can discover them. Use stable CC0 sources (e.g. Wikimedia Commons "Category:CC0" direct file URLs, or a documented picsum/openverse set) and verify each download's content-type is an image; skip failures with a warning. Keep total under ~30 MB. Document the licence/source in a `data/content/README.txt` it writes.
- [ ] **Step 2: Verify (lint + shape only; no network in CI)**
```bash
sh -n bin/fetch-sample-images.sh && echo "OK sh syntax"
grep -q 'og:image' bin/fetch-sample-images.sh && grep -q 'data/content' bin/fetch-sample-images.sh && echo "OK content shape"
```
Real download + crawl is exercised in Part C.
- [ ] **Step 3: Commit** `git add bin/fetch-sample-images.sh data/content/.gitkeep && git commit -m "feat: fetch-sample-images.sh seeds crawlable demo content"`

---

### Task B8: `compose-production.yaml` overlay

**Files:** Rewrite `compose-production.yaml`; create `data/https-portal/conf/multimodal.codelibs.org.ssl.conf.erb`.

- [ ] **Step 1:** Write the overlay adding `https-portal` (`steveltn/https-portal:1`, ports 80/443, `DOMAINS: '${DOMAIN} -> http://fess01:8080'`, `STAGE: production`, `X-Frame-Options SAMEORIGIN`, mount `ssl_certs` + the per-domain `.ssl.conf.erb`) and overriding `search01` heap to `${OPENSEARCH_HEAP_PROD}`. Mirror `docker-semanticsearch/compose-production.yaml`.
- [ ] **Step 2: Verify** `docker compose -f compose.yaml -f compose-production.yaml config >/dev/null && echo "OK prod overlay valid"`
- [ ] **Step 3: Commit** `git add compose-production.yaml data/https-portal && git commit -m "feat: production TLS overlay"`

---

### Task B9: `README.md` rewrite

**Files:** Rewrite `README.md`.

- [ ] **Step 1:** Write the README: title/intro (multimodal gallery search on Fess), architecture diagram (the §5 services), Getting Started (`cp .env.example .env` → `bash bin/setup.sh` → `docker compose up -d` → wait for healthy → `bash bin/fetch-sample-images.sh` → crawl `http://content/` → search at `http://localhost:8080/`), a **prominent note** on the `-noble` image (why the default Alpine image shows broken image tiles — no ImageMagick/poppler/LibreOffice), the crawl-and-search walkthrough, model swap (multilingual default ↔ `xlm-roberta-large-ViT-H-14` max-quality: set `CLIP_MODEL_NAME`+`MULTIMODAL_DIMENSION=1024`, then re-crawl/reindex), the `mosaic` theme + how to change `THEME_NAME`, production/TLS, and troubleshooting (thumbnails warm up over ~1 min; model download size; loopback-only 9200). Note FiftyOne as an optional larger dataset.
- [ ] **Step 2: Verify** `grep -q "15.7.0-noble" README.md && grep -q "mosaic" README.md && grep -q "content" README.md && echo OK`
- [ ] **Step 3: Commit** `git add README.md && git commit -m "docs: rewrite README for modernized multimodal gallery stack"`

---

# PART C — Integration & delivery

### Task C1: End-to-end bring-up + in-browser verification

**Prereq:** Part A merged/available (use `FESS_THEMES_DIR` pointing at the local `fess-themes` `feature/mosaic-theme` checkout so the theme need not be pushed first).

- [ ] **Step 1: Bring up the stack**
```bash
cd docker-multimodalsearch
cp .env.example .env
# dev: point at the local theme checkout
echo "FESS_THEMES_DIR=$(cd ../fess-workspace/repos/fess-themes && pwd)" >> .env   # adjust path
bash bin/setup.sh
docker compose up -d
```
- [ ] **Step 2: Wait for health + confirm no manual steps**
```bash
# poll until all healthy; then confirm init-fess-index completed
docker compose ps
docker compose logs init-fess-index | tail -n 20      # expect: content_vector present / reindex done
```
Expected: `search01`, `clip_server`, `content`, `fess01` healthy; `init-fess-index` exited 0.
- [ ] **Step 3: Seed content + crawl**
```bash
bash bin/fetch-sample-images.sh
```
Then create + run a Web crawler for `http://content/` (via Admin UI or the documented API flow), and wait for indexing + the every-minute thumbnail job. Confirm the mapping carries the vector field:
```bash
curl -s "http://localhost:8080/api/v2/search?q=*&num=1" | jq '.response.record_count'   # > 0 after crawl
```
- [ ] **Step 4: Browser verification (Claude in Chrome)** — verify on `http://localhost:8080/`:
  - Home hero renders + typewriter cycles; `prefers-reduced-motion` freezes it.
  - A text query returns a **masonry gallery**; thumbnails load (with brief 404-retry warm-up), no broken tiles for images/PDF/Office (proves `-noble`).
  - A **Japanese** query (e.g. "夕焼けの車") returns relevant images (proves multilingual model).
  - **Mixed results**: image tiles + text-doc tiles/cards; fallback typed cards for thumbnail-less docs.
  - Searcher badges show Keyword/Visual/Blend (proves the `.api.` searcher prop).
  - Lightbox: click a tile → full-size image + metadata; arrow-key next/prev; Esc closes.
  - Grid/list toggle; filter rail; pagination; suggest; mobile offcanvas.
  - DevTools console: **no CSP violations**.
- [ ] **Step 5: Capture** a short screen recording / screenshots of the gallery + lightbox for the PR. Record any defects as follow-up fixes (loop back to the relevant Part-A/B task).
- [ ] **Step 6:** No commit (verification task) — or commit any fixes made under their originating task's message.

---

### Task C2: Open the `fess-themes` PR

- [ ] **Step 1:** Ensure `gh auth setup-git`; push `feature/mosaic-theme` over HTTPS (`git push https://github.com/codelibs/fess-themes.git feature/mosaic-theme`, with sandbox disabled as needed).
- [ ] **Step 2:** `gh pr create --repo codelibs/fess-themes` — title `feat: add mosaic theme (thumbnail gallery for multimodal search)`; body summarizing the gallery UX, searcher badges, thumbnail-endpoint handling, CSP-widening rationale, and 16-locale parity. **No claude.ai/session links; no internal info.**
- [ ] **Step 3:** Paste 1–2 gallery/lightbox screenshots from C1.

---

### Task C3: Open the `docker-multimodalsearch` PR

- [ ] **Step 1:** Update `.env.example` `FESS_THEMES_REF` to the merged theme ref (or leave `main` if the theme PR is merged). Remove any local `FESS_THEMES_DIR` line from `.env` (not tracked anyway).
- [ ] **Step 2:** Push `feature/fess-15.7-multimodal-gallery` over HTTPS; `gh pr create --repo codelibs/docker-multimodalsearch` — title `feat: modernize to Fess 15.7 / OpenSearch 3.7 with multimodal gallery theme`; body summarizing versions, `.env` config, thumbnail-capable `-noble` image, hybrid multimodal, multilingual model, init automation, and the `mosaic` theme. **No claude.ai/session links; no internal info.**
- [ ] **Step 3:** Link the `fess-themes` PR as a dependency in the body.

---

## Self-Review

**Spec coverage:** §4 decisions → B1–B4 (versions/env/props), B6 (theme sync/model render), A7 (CSP), A2/A8 (badges/i18n), B5 (reindex), B7 (demo content); §6 theme → A1–A9; §7 infra → B1–B9; §8 non-goals honored (no plugin change; hidden image-drop = A-scaffold inherits semanticlens's hidden affordance, no new work); §9 verification → C1. No uncovered spec section.

**Placeholder scan:** No "TBD/TODO". Large ported files (semanticlens→mosaic) use precise edit-specs + concrete code for novel logic (tiles/retry/badge/lightbox/hero) rather than re-dumping thousands of ported lines — appropriate for a port, not a placeholder. Every code step shows real code or an exact command with expected output.

**Type consistency:** `searcherBadgeKind(doc)` returns `keyword|visual|blend|other|null` used consistently in A2 (tiles), A3 (lightbox meta), A6 (composition), A8 (i18n keys `searcher.keyword/visual/blend/other`). `thumbUrl(docId,queryId)` used in A2 + A3. `state.currentEnv`/`state.lbRank` defined A2/A3 and consumed A3/A4. `__CLIP_MODEL_NAME__` placeholder (B2) matched by the `sed` in B6. `MULTIMODAL_DIMENSION`/`CLIP_MODEL_NAME` names identical across `.env.example` (B1), compose (B4), clip template (B2/B6).

**Adaptation note:** Where no unit-test harness exists (theme JS, shell, compose), "tests" are contract/behavior checks with exact commands + expected output, plus the Part-C browser gate — the honest verification path for this stack.
