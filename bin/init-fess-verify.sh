#!/bin/sh
set -eu

# One-shot mapping check for the Fess 15.8 multimodal stack.
#
# Fess 15.8 builds the content_chunk_vector kNN field into the document index
# statically (fess_indices/fess/doc.json), substituting the configured dimension,
# method, engine and space_type at index-creation time. There is therefore no
# reindex workaround to perform any more -- 15.7's bin/init-fess-index.sh, which
# logged into the admin UI and triggered Admin > Maintenance > Reindex, is gone.
#
# What is still worth failing fast on is a mismatch between the running
# configuration and an index that was created under a different one: the mapping is
# frozen at creation, so a dimension change looks like "search returns nothing"
# rather than an error. This script turns that into an explicit failure.
#
# Runs in alpine; /bin/sh, no bash-isms, no pipefail.

: "${SEARCH_ENGINE_HTTP_URL:=http://search01:9200}"
: "${MULTIMODAL_DIMENSION:=512}"
: "${KNN_ENGINE:=lucene}"
: "${MAX_WAIT:=300}"

INDEX_ALIAS="fess.search"

log() { echo "[init-fess-verify] $*"; }
die() { echo "[init-fess-verify] ERROR: $*" >&2; exit 1; }

# Wait for the search alias to resolve. curl exits non-zero on connection failure,
# which `set -e` would treat as fatal, so every probe is guarded with `|| true`.
log "Waiting up to ${MAX_WAIT}s for ${INDEX_ALIAS} mapping..."
waited=0
mapping=""
while [ "${waited}" -lt "${MAX_WAIT}" ]; do
  mapping="$(curl -fsS "${SEARCH_ENGINE_HTTP_URL}/${INDEX_ALIAS}/_mapping" 2>/dev/null || true)"
  if [ -n "${mapping}" ] && echo "${mapping}" | jq -e 'length > 0' >/dev/null 2>&1; then
    break
  fi
  sleep 5
  waited=$((waited + 5))
  mapping=""
done
[ -n "${mapping}" ] || die "${INDEX_ALIAS} did not become available within ${MAX_WAIT}s. Check: docker compose logs fess01"

vector="$(echo "${mapping}" | jq -c '[.[].mappings.properties.content_chunk_vector.properties.vector][0] // empty')"
if [ -z "${vector}" ] || [ "${vector}" = "null" ]; then
  die "content_chunk_vector.vector is missing from ${INDEX_ALIAS}.
     The index predates this configuration (Fess 15.8 creates the field on index creation).
     Fix: Admin > Maintenance > Reindex with 'Update aliases' checked, then re-crawl."
fi

dimension="$(echo "${vector}" | jq -r '.dimension // empty')"
engine="$(echo "${vector}" | jq -r '.method.engine // empty')"
space_type="$(echo "${vector}" | jq -r '.method.space_type // empty')"

if [ "${dimension}" != "${MULTIMODAL_DIMENSION}" ]; then
  die "dimension mismatch: index=${dimension}, configured MULTIMODAL_DIMENSION=${MULTIMODAL_DIMENSION}.
     The dimension is frozen when the index is created, so this cannot self-heal.
     Fix: (1) confirm MULTIMODAL_DIMENSION matches CLIP_MODEL_NAME,
          (2) confirm data/fess/opt/fess/system.properties has no content_chunker.* lines
              (file values win over -Dfess.system.*),
          (3) Admin > Maintenance > Reindex with 'Update aliases',
          (4) re-crawl -- a reindex copies documents, it does not recompute embeddings."
fi

if [ "${engine}" != "${KNN_ENGINE}" ]; then
  die "kNN engine mismatch: index=${engine}, configured KNN_ENGINE=${KNN_ENGINE}. Reindex to rebuild the mapping."
fi

# index.knn lives in the index SETTINGS, not in _mapping. Without it OpenSearch falls
# back to an exact full scan: correct results, slower. WARN rather than fail.
settings="$(curl -fsS "${SEARCH_ENGINE_HTTP_URL}/${INDEX_ALIAS}/_settings" 2>/dev/null || true)"
knn="$(echo "${settings}" | jq -r '[.[].settings.index.knn][0] // empty' 2>/dev/null || true)"
if [ "${knn}" != "true" ]; then
  log "WARNING: index.knn is '${knn:-unset}' (expected 'true'). kNN queries fall back to an exact scan."
fi

log "OK: dimension=${dimension}, engine=${engine}, space_type=${space_type}, index.knn=${knn:-unset}"
