# Upgrading

Notes for moving an existing stack to a newer release of this repository, newest first. For a fresh install, see [README.md](README.md).

## Upgrading from 15.9 to 15.10

The index, the stored vectors and the scheduled jobs carry over: the jobs are already
JavaScript, so nothing needs migrating, and no reindex is required. Verified on a stack
upgraded from Fess 15.9.0, where all stored vectors and the document count were
unchanged after the upgrade and a re-crawl.

1. Update the repo and `.env` (the defaults already follow 15.10: `FESS_VERSION=snapshot`,
   `FESS_PLUGINS=fess-webapp-multimodal:15.10.0-SNAPSHOT`, `FESS_THEMES_REF=main`).
   If your `.env` pins 15.9, remove those pins.
2. Re-run setup (it regenerates `generate-thumbnail` from the new image and re-syncs the
   theme) and recreate the stack:
   ```sh
   bash bin/setup.sh
   docker compose pull
   docker compose up -d
   ```
3. Hard-reload the browser (or clear the site's cache). Theme assets are served with
   `Cache-Control: max-age=86400`, so the old mosaic can linger for a day.

**Re-index the image documents.** Fess 15.10 stores only the descriptive metadata of an
image (title, description, creator) in `content`; 15.9 stored a full metadata dump, up to
about 34,000 characters per image. A re-crawl does not rewrite documents the crawler
considers unchanged, so documents crawled on 15.9 keep the long `content`. A crawl on a
fresh index produces `content` of at most a few hundred characters. To get the new
behaviour for existing documents, delete them and crawl again, as described under
[Thumbnail size](README.md#thumbnail-size) (that crawl rebuilds the vectors and the thumbnails).

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
| `fess.multimodal.min_score` (engine score) | `content_chunker.search.min_score` (**raw cosine** — see [below](#clip_min_cosine-the-units-changed)) |

Also removed:

- **`-Dfess.config.job.system.property.filter.pattern`** — no longer needed. `ExecJob`
  forwards the `fess.system.` prefix to child processes automatically.
- **`-Dthumbnail.width` / `-Dthumbnail.height`** — these keys never existed in the Fess
  core and did nothing. Use `THUMBNAIL_SIZE` (see [Thumbnail size](README.md#thumbnail-size)).

Newly required:

- **`-Dfess.system.content_chunker.enabled=true`** and
  **`-Dfess.system.content_chunker.search.enabled=true`** turn the core's chunk pipeline
  and its search branch on. `content_chunker.search.enabled` is read once at startup, so
  enabling it later needs a restart.
- **`-Dfess.system.content_chunker.embedding.name=clip`** points core's
  `EmbeddingClientManager` at the plugin's `clipEmbeddingClient`.

Migration steps:

1. Update `.env` (see [Configuration reference](README.md#configuration-reference)); convert
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
