#!/bin/bash
set -euo pipefail

# Run from the repo root regardless of the caller's CWD (script lives in bin/).
cd "$(dirname "$0")/.."

# Host-side setup for docker-multimodalsearch:
#   - load configuration from .env (bootstrapped from .env.example on first run)
#   - create the bind-mount data directories
#   - seed the live system.properties from the tracked template (first run only)
#   - sync the static UI theme from fess-themes
#   - drop any stale multimodal plugin jar (plugins now come via FESS_PLUGINS,
#     not a locally downloaded jar)
#
# This script does not talk to Docker, Fess, or OpenSearch; re-running it is safe.

if [ ! -f .env ]; then
  echo "No .env found; creating one from .env.example..."
  cp .env.example .env
fi

# Read only the keys this script needs from .env WITHOUT sourcing it (docker
# compose parses .env declaratively; sourcing would execute values and break on
# spaces/special chars in unrelated keys like FESS_ADMIN_PASSWORD).
env_get() {
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | tail -n1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]*$//'
}
THEME_NAME="${THEME_NAME:-$(env_get THEME_NAME)}"
FESS_THEMES_REPO="${FESS_THEMES_REPO:-$(env_get FESS_THEMES_REPO)}"
FESS_THEMES_REF="${FESS_THEMES_REF:-$(env_get FESS_THEMES_REF)}"
FESS_THEMES_DIR="${FESS_THEMES_DIR:-$(env_get FESS_THEMES_DIR)}"

# Defaults mirror .env.example; used if a key is missing from both the
# environment and .env.
THEME_NAME="${THEME_NAME:-mosaic}"
FESS_THEMES_REPO="${FESS_THEMES_REPO:-https://github.com/codelibs/fess-themes.git}"
FESS_THEMES_REF="${FESS_THEMES_REF:-main}"

# clip_server runs as a non-root user (docker/clip-server/Dockerfile creates the
# "clip" user; compose runs it as `user: "${CLIP_UID:-1000}:${CLIP_GID:-1000}"`).
# Pin that UID/GID to the host user so the bind-mounted model cache
# (./data/clip_server/cache) stays writable when the container downloads the
# model on first boot. docker compose reads .env declaratively and cannot run
# `id`, so persist the resolved values into .env when they are absent.
CLIP_UID="${CLIP_UID:-$(env_get CLIP_UID)}"
CLIP_GID="${CLIP_GID:-$(env_get CLIP_GID)}"
# Fall back to the host user for empty or non-numeric values so an unset key, a
# blank `CLIP_UID=`, or a CRLF/whitespace-polluted .env can never yield an
# invalid compose `user:` spec or diverge from the chown below.
case "${CLIP_UID}" in "" | *[!0-9]*) CLIP_UID="$(id -u)" ;; esac
case "${CLIP_GID}" in "" | *[!0-9]*) CLIP_GID="$(id -g)" ;; esac
grep -qE '^CLIP_UID=[0-9]' .env 2>/dev/null || printf 'CLIP_UID=%s\n' "${CLIP_UID}" >> .env
grep -qE '^CLIP_GID=[0-9]' .env 2>/dev/null || printf 'CLIP_GID=%s\n' "${CLIP_GID}" >> .env

THEME_DEST="./data/fess/usr/share/fess/app/themes/${THEME_NAME}"

# A previous run may have chowned ./data to the container UIDs (1001/1000). Reclaim
# it for the host user so this re-run can modify/replace files (theme sync,
# plugin cleanup).
if [ "$(uname -s)" = "Linux" ] && [ -d ./data ]; then
  sudo chown -R "$(id -u)" ./data
fi

echo "Creating directories..."
mkdir -p ./data/opensearch/usr/share/opensearch/data
mkdir -p ./data/opensearch/usr/share/opensearch/config/dictionary
mkdir -p ./data/fess/opt/fess
mkdir -p ./data/fess/var/lib/fess
mkdir -p ./data/fess/var/log/fess
mkdir -p ./data/fess/usr/share/fess/app/WEB-INF/plugin
mkdir -p ./data/fess/usr/share/fess/app/themes
mkdir -p ./data/content
touch ./data/content/.gitkeep
mkdir -p ./data/clip_server/cache
mkdir -p ./data/https-portal/ssl_certs

# Seed the live system.properties from the tracked template on first run only.
# The live file is git-ignored so Fess can rewrite it (Admin > General) without
# causing git-pull conflicts; an existing file is preserved. To reset to defaults,
# delete it and re-run this script.
SYSTEM_PROPERTIES=./data/fess/opt/fess/system.properties
if [ ! -f "${SYSTEM_PROPERTIES}" ]; then
  echo "Creating ${SYSTEM_PROPERTIES} from template (theme.default=${THEME_NAME})..."
  cp "${SYSTEM_PROPERTIES}.template" "${SYSTEM_PROPERTIES}"
  sed -i.bak "s|^theme\.default=.*|theme.default=${THEME_NAME}|" "${SYSTEM_PROPERTIES}"
  rm -f "${SYSTEM_PROPERTIES}.bak"
else
  current="$(grep -E '^theme\.default=' "${SYSTEM_PROPERTIES}" | head -n1 | cut -d= -f2- || true)"
  if [ -n "${current}" ] && [ "${current}" != "${THEME_NAME}" ]; then
    echo "WARNING: live theme.default='${current}' but THEME_NAME='${THEME_NAME}'. Fess will keep using '${current}'."
    echo "         To switch: edit ${SYSTEM_PROPERTIES} (or Admin > General), or delete it and re-run this script."
  fi
fi

echo "Syncing '${THEME_NAME}' theme from fess-themes..."
# Source resolution:
#   FESS_THEMES_DIR -> copy from a local fess-themes checkout (e.g. ../fess-workspace/repos/fess-themes)
#   otherwise       -> shallow clone FESS_THEMES_REPO @ FESS_THEMES_REF
tmpdir=""
staging="$(mktemp -d)"
cleanup() { rm -rf "${staging}" ${tmpdir:+"${tmpdir}"}; }
trap cleanup EXIT

if [ -n "${FESS_THEMES_DIR:-}" ]; then
  src="${FESS_THEMES_DIR}/themes/${THEME_NAME}"
  if [ ! -f "${src}/theme.yml" ]; then
    echo "ERROR: ${src}/theme.yml not found (check FESS_THEMES_DIR / THEME_NAME)." >&2
    exit 1
  fi
else
  tmpdir="$(mktemp -d)"
  git clone --depth 1 --branch "${FESS_THEMES_REF}" "${FESS_THEMES_REPO}" "${tmpdir}/fess-themes"
  src="${tmpdir}/fess-themes/themes/${THEME_NAME}"
  if [ ! -f "${src}/theme.yml" ]; then
    echo "ERROR: ${src}/theme.yml not found in ${FESS_THEMES_REPO}@${FESS_THEMES_REF}." >&2
    exit 1
  fi
fi
cp -R "${src}/." "${staging}/"
rm -rf "${THEME_DEST}"
mkdir -p "${THEME_DEST}"
cp -R "${staging}/." "${THEME_DEST}/"
echo "Theme synced to ${THEME_DEST}"

# Drop any previously installed multimodal plugin jar so a FESS_PLUGINS version
# change doesn't leave two versions in the persisted plugin dir (Fess would load
# duplicate components). The image reinstalls the pinned version from
# FESS_PLUGINS on the next `docker compose up`; this script never downloads jars.
rm -f ./data/fess/usr/share/fess/app/WEB-INF/plugin/fess-webapp-multimodal-*.jar

if [ "$(uname -s)" = "Linux" ]; then
  echo "Changing ownership for bind-mount directories..."
  sudo chown -R root ./data/https-portal/ssl_certs
  sudo chown -R 1001 ./data/fess/opt/fess
  sudo chown -R 1001 ./data/fess/var/lib/fess
  sudo chown -R 1001 ./data/fess/var/log/fess
  sudo chown -R 1001 ./data/fess/usr/share/fess/app/WEB-INF/plugin
  sudo chown -R 1001 ./data/fess/usr/share/fess/app/themes
  sudo chown -R 1000 ./data/opensearch/usr/share/opensearch/data
  sudo chown -R 1000 ./data/opensearch/usr/share/opensearch/config/dictionary
  sudo chown -R "${CLIP_UID}:${CLIP_GID}" ./data/clip_server/cache
fi

echo "Setup complete. Next: docker compose up -d"
