#!/usr/bin/env bash
set -euo pipefail

# Seeds ./data/content/ with a small, mixed, crawlable demo corpus for the
# multimodal gallery demo:
#   - ~35 CC0/CC-BY/CC-BY-SA/public-domain photos from Wikimedia Commons,
#     spanning animals/vehicles/food/nature/buildings (so text->image CLIP
#     queries have varied, recognizable subjects to match).
#   - 3 short HTML pages, each with an og:image meta tag (so the HTML docs
#     also get a thumbnail), linked from images/.
#   - 1 small, locally generated PDF (no network needed for it).
#   - index.html linking to every image/page/doc so Fess's web crawler can
#     discover everything by following links from http://content/.
#   - README.txt documenting the exact source + license of every image.
#
# This script only touches ./data/content/ (gitignored except .gitkeep) and
# never talks to Docker/Fess/OpenSearch. Safe to re-run: already-downloaded
# files are left alone (idempotent), and a failed download only WARNs and
# moves on to the next file (never aborts the whole run).
#
# Run from the repo root regardless of the caller's CWD (script lives in bin/).
cd "$(dirname "$0")/.."

CONTENT_DIR="./data/content"
IMAGES_DIR="${CONTENT_DIR}/images"
PAGES_DIR="${CONTENT_DIR}/pages"
DOCS_DIR="${CONTENT_DIR}/docs"
BASE_URL="http://content"
USER_AGENT="docker-multimodalsearch-fetch-sample-images/1.0 (+https://github.com/codelibs/docker-multimodalsearch)"

log()  { echo "[fetch-sample-images] $*"; }
warn() { echo "[fetch-sample-images] WARNING: $*" >&2; }

mkdir -p "${IMAGES_DIR}" "${PAGES_DIR}" "${DOCS_DIR}"

# --- Downloader detection (curl preferred, wget as a fallback) -------------
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER=curl
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER=wget
else
  echo "[fetch-sample-images] ERROR: neither curl nor wget is available." >&2
  exit 1
fi

# Download $1 (URL) to $2 (destination path). Returns non-zero on any HTTP
# or network failure; the caller is responsible for verifying the result and
# cleaning up on failure.
download() {
  url="$1"
  out="$2"
  case "${DOWNLOADER}" in
    curl)
      curl -fsSL -A "${USER_AGENT}" --connect-timeout 10 --max-time 60 -o "${out}" "${url}"
      ;;
    wget)
      wget -q -U "${USER_AGENT}" --timeout=60 --tries=1 -O "${out}" "${url}"
      ;;
  esac
}

# True when $1 looks like an image file, based on its magic bytes (not the
# extension or an HTTP header, so it also catches "200 OK" HTML error/
# interstitial pages some hosts return in place of the real file).
is_image_file() {
  f="$1"
  [ -s "${f}" ] || return 1
  header="$(od -An -tx1 -N 12 "${f}" 2>/dev/null | tr -d ' \n')"
  case "${header}" in
    ffd8ff*) return 0 ;;                        # JPEG
    89504e470d0a1a0a*) return 0 ;;               # PNG
    474946383761*|474946383961*) return 0 ;;     # GIF87a / GIF89a
    52494646*57454250*) return 0 ;;              # RIFF....WEBP
    *) return 1 ;;
  esac
}

# --- Sample image set --------------------------------------------------
# category|slug|license|artist/author|source URL (stable upload.wikimedia.org
# link)|original Wikimedia Commons file title
#
# All entries are real, currently-valid Wikimedia Commons files (verified
# when this script was written) under CC0, CC-BY, CC-BY-SA, or Public Domain
# terms -- no GFDL-only files are used, since GFDL requires bundling the full
# license text to redistribute. See the generated README.txt for the full
# attribution table.
IMAGES=(
  'animal|cat|CC0|Marko Milivojevic (via Pixnio)|https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Domestic_shorthair_cat_portrait_in_grass.jpg/960px-Domestic_shorthair_cat_portrait_in_grass.jpg|Domestic shorthair cat portrait in grass.jpg'
  'animal|dog|Public domain|Herwig Kavallar|https://upload.wikimedia.org/wikipedia/commons/thumb/9/90/Labrador_Retriever_portrait.jpg/960px-Labrador_Retriever_portrait.jpg|Labrador Retriever portrait.jpg'
  'animal|retriever|CC BY-SA 4.0|Morphdog|https://upload.wikimedia.org/wikipedia/commons/thumb/b/b5/Golden_Retriever_medium-to-light-coat.jpg/960px-Golden_Retriever_medium-to-light-coat.jpg|Golden Retriever medium-to-light-coat.jpg'
  'animal|horse|CC BY-SA 3.0|Francois Marchal; derivative: Dana boomer|https://upload.wikimedia.org/wikipedia/commons/d/de/Nokota_Horses_cropped.jpg|Nokota Horses cropped.jpg'
  'animal|elephant|CC0|Candy Piercy|https://upload.wikimedia.org/wikipedia/commons/thumb/8/84/African_Bull_elephant_walking_towards_camera_in_August_2013.jpg/960px-African_Bull_elephant_walking_towards_camera_in_August_2013.jpg|African Bull elephant walking towards camera in August 2013.jpg'
  'animal|tiger|CC BY-SA 4.0|Charles J. Sharp|https://upload.wikimedia.org/wikipedia/commons/thumb/3/3f/Walking_tiger_female.jpg/960px-Walking_tiger_female.jpg|Walking tiger female.jpg'
  'animal|panda|Public domain|Jeff Kubina|https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Giant_Panda_2004-03-2.jpg/960px-Giant_Panda_2004-03-2.jpg|Giant Panda 2004-03-2.jpg'
  'animal|penguin|CC BY-SA 3.0|Samuel Blanc|https://upload.wikimedia.org/wikipedia/commons/0/07/Emperor_Penguin_Manchot_empereur.jpg|Emperor Penguin Manchot empereur.jpg'
  'animal|lion|CC BY 2.0|Kevin Pluck|https://upload.wikimedia.org/wikipedia/commons/thumb/7/73/Lion_waiting_in_Namibia.jpg/960px-Lion_waiting_in_Namibia.jpg|Lion waiting in Namibia.jpg'
  'animal|fox|CC0|Joanne Redwood|https://upload.wikimedia.org/wikipedia/commons/thumb/3/30/Vulpes_vulpes_ssp_fulvus.jpg/960px-Vulpes_vulpes_ssp_fulvus.jpg|Vulpes vulpes ssp fulvus.jpg'
  'animal|owl|CC BY-SA 4.0|Rhododendrites|https://upload.wikimedia.org/wikipedia/commons/thumb/3/31/Eurasian_eagle-owl_%2844088%29.jpg/960px-Eurasian_eagle-owl_%2844088%29.jpg|Eurasian eagle-owl (44088).jpg'
  'animal|koala|CC BY-SA 3.0|Diliff|https://upload.wikimedia.org/wikipedia/commons/thumb/4/49/Koala_climbing_tree.jpg/960px-Koala_climbing_tree.jpg|Koala climbing tree.jpg'
  'vehicle|ship|CC BY-SA 3.0|Raphodon|https://upload.wikimedia.org/wikipedia/commons/thumb/e/e7/Sailing_ship_Christian_Radich.jpg/960px-Sailing_ship_Christian_Radich.jpg|Sailing ship Christian Radich.jpg'
  'vehicle|car|Public domain|Alexandre Louis|https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/A_Brouhot_car_in_Paris%2C_1910.jpg/960px-A_Brouhot_car_in_Paris%2C_1910.jpg|A Brouhot car in Paris, 1910.jpg'
  'vehicle|bicycle|CC BY-SA 3.0|Tomascastelazo|https://upload.wikimedia.org/wikipedia/commons/thumb/0/02/Bicycle_reflections.jpg/960px-Bicycle_reflections.jpg|Bicycle reflections.jpg'
  'vehicle|airplane|CC BY-SA 2.0|Katsuhiko Tokunaga/SuperJet International|https://upload.wikimedia.org/wikipedia/commons/thumb/7/77/Air-to-air_photo_of_a_Sukhoi_Superjet_100_%2897004%29_over_Italy.jpg/960px-Air-to-air_photo_of_a_Sukhoi_Superjet_100_%2897004%29_over_Italy.jpg|Air-to-air photo of a Sukhoi Superjet 100 (97004) over Italy.jpg'
  'vehicle|train|CC BY-SA 2.0|Drew Jacksich; derivative: Bruce1ee|https://upload.wikimedia.org/wikipedia/commons/thumb/5/57/Union_Pacific_844%2C_Painted_Rocks%2C_NV%2C_2009_%28crop%29.jpg/960px-Union_Pacific_844%2C_Painted_Rocks%2C_NV%2C_2009_%28crop%29.jpg|Union Pacific 844, Painted Rocks, NV, 2009 (crop).jpg'
  'vehicle|hotairballoon|CC BY-SA 3.0|Benh LIEU SONG (Flickr)|https://upload.wikimedia.org/wikipedia/commons/thumb/8/89/Cappadocia_Balloon_Inflating_Wikimedia_Commons.JPG/960px-Cappadocia_Balloon_Inflating_Wikimedia_Commons.JPG|Cappadocia Balloon Inflating Wikimedia Commons.JPG'
  'food|pizza|CC BY-SA 3.0|Valerio Capello at English Wikipedia|https://upload.wikimedia.org/wikipedia/commons/thumb/a/a3/Eq_it-na_pizza-margherita_sep2005_sml.jpg/960px-Eq_it-na_pizza-margherita_sep2005_sml.jpg|Eq it-na pizza-margherita sep2005 sml.jpg'
  'food|sushi|CC BY-SA 2.0|chidorian from Japan|https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/Sushi_platter.jpg/960px-Sushi_platter.jpg|Sushi platter.jpg'
  'food|apple|CC BY 2.0|Abhijit Tembhekar from Mumbai, India|https://upload.wikimedia.org/wikipedia/commons/thumb/1/15/Red_Apple.jpg/960px-Red_Apple.jpg|Red Apple.jpg'
  'food|hamburger|Public domain|Len Rizzi (photographer), reprocessed by Off-shell|https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/Hamburger_%28black_bg%29.jpg/960px-Hamburger_%28black_bg%29.jpg|Hamburger (black bg).jpg'
  'food|coffee|CC BY-SA 2.0|Julius Schorzman|https://upload.wikimedia.org/wikipedia/commons/thumb/4/45/A_small_cup_of_coffee.JPG/960px-A_small_cup_of_coffee.JPG|A small cup of coffee.JPG'
  'food|bread|CC0|Cheikhelball|https://upload.wikimedia.org/wikipedia/commons/thumb/3/38/Pain_traditionnel.jpg/960px-Pain_traditionnel.jpg|Pain traditionnel.jpg'
  'food|orange|CC BY-SA 3.0|Evan-Amos|https://upload.wikimedia.org/wikipedia/commons/thumb/c/c4/Orange-Fruit-Pieces.jpg/960px-Orange-Fruit-Pieces.jpg|Orange-Fruit-Pieces.jpg'
  'nature|sunset|CC BY-SA 3.0|Alvesgaspar|https://upload.wikimedia.org/wikipedia/commons/thumb/5/58/Sunset_2007-1.jpg/960px-Sunset_2007-1.jpg|Sunset 2007-1.jpg'
  'nature|mountain|Public domain|NASA|https://upload.wikimedia.org/wikipedia/commons/thumb/7/79/Himalayas.jpg/960px-Himalayas.jpg|Himalayas.jpg'
  'nature|waterfall|CC BY-SA 4.0|Frank Schulenburg|https://upload.wikimedia.org/wikipedia/commons/thumb/5/56/Waterfall_in_Russian_Gulch_State_Park.jpg/960px-Waterfall_in_Russian_Gulch_State_Park.jpg|Waterfall in Russian Gulch State Park.jpg'
  'nature|forest|CC0|W.carter|https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/Spruce_forest_at_Holma.jpg/960px-Spruce_forest_at_Holma.jpg|Spruce forest at Holma.jpg'
  'nature|beach|CC BY-SA 4.0|Michal Klajban|https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Mystic_Beach%2C_Vancouver_Island%2C_Canada_10.jpg/960px-Mystic_Beach%2C_Vancouver_Island%2C_Canada_10.jpg|Mystic Beach, Vancouver Island, Canada 10.jpg'
  'nature|desert|Public domain|Bureau of Land Management - Utah/Bob Wick|https://upload.wikimedia.org/wikipedia/commons/thumb/c/cb/Utah_Dunes_Landscape_-_West_Desert_District.jpg/960px-Utah_Dunes_Landscape_-_West_Desert_District.jpg|Utah Dunes Landscape - West Desert District.jpg'
  'building|eiffeltower|Public domain|Benh LIEU SONG|https://upload.wikimedia.org/wikipedia/commons/thumb/a/a8/Tour_Eiffel_Wikimedia_Commons.jpg/960px-Tour_Eiffel_Wikimedia_Commons.jpg|Tour Eiffel Wikimedia Commons.jpg'
  'building|colosseum|CC BY-SA 4.0|FeaturedPics|https://upload.wikimedia.org/wikipedia/commons/thumb/d/de/Colosseo_2020.jpg/960px-Colosseo_2020.jpg|Colosseo 2020.jpg'
  'building|bigben|CC BY 2.5|Diliff|https://upload.wikimedia.org/wikipedia/commons/thumb/9/93/Clock_Tower_-_Palace_of_Westminster%2C_London_-_May_2007.jpg/960px-Clock_Tower_-_Palace_of_Westminster%2C_London_-_May_2007.jpg|Clock Tower - Palace of Westminster, London - May 2007.jpg'
  'building|operahouse|CC BY-SA 3.0|Diliff|https://upload.wikimedia.org/wikipedia/commons/thumb/7/7c/Sydney_Opera_House_-_Dec_2008.jpg/960px-Sydney_Opera_House_-_Dec_2008.jpg|Sydney Opera House - Dec 2008.jpg'
  'building|castle|CC BY-SA 3.0|Softeis|https://upload.wikimedia.org/wikipedia/commons/thumb/a/ae/Castle_Neuschwanstein.jpg/960px-Castle_Neuschwanstein.jpg|Castle Neuschwanstein.jpg'
  'building|lighthouse|CC BY-SA 4.0|Frank Schulenburg|https://upload.wikimedia.org/wikipedia/commons/thumb/d/d4/Point_Reyes_Lighthouse_in_December_2019.jpg/960px-Point_Reyes_Lighthouse_in_December_2019.jpg|Point Reyes Lighthouse in December 2019.jpg'
)

log "Fetching ${#IMAGES[@]} sample images into ${IMAGES_DIR} ..."
downloaded=0
skipped=0
failed=0
for entry in "${IMAGES[@]}"; do
  IFS='|' read -r category slug license artist url title <<< "${entry}"
  dest="${IMAGES_DIR}/${slug}.jpg"

  if [ -s "${dest}" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  tmp="$(mktemp "${dest}.XXXXXX")"
  if ! download "${url}" "${tmp}"; then
    warn "download failed, skipping: ${slug} (${url})"
    rm -f "${tmp}"
    failed=$((failed + 1))
    sleep 0.3
    continue
  fi
  if ! is_image_file "${tmp}"; then
    warn "downloaded file is not a recognizable image, skipping: ${slug} (${url})"
    rm -f "${tmp}"
    failed=$((failed + 1))
    sleep 0.3
    continue
  fi
  mv "${tmp}" "${dest}"
  downloaded=$((downloaded + 1))
  log "downloaded ${slug}.jpg"
  sleep 0.3
done
log "Images: ${downloaded} downloaded, ${skipped} already present, ${failed} failed."

# --- Minimal sample PDF (generated locally; no network needed) -------------
# Hand-built single-page PDF (Catalog/Pages/Page/Contents/Font, byte-exact
# xref table) so Fess's PDF crawling/thumbnailing has something to exercise
# even if this script is ever run fully offline. Wrapped so a failure here
# (should not normally happen; it's pure local text generation) only warns
# instead of aborting the rest of the run, per the brief.
generate_sample_pdf() {
  dest="${DOCS_DIR}/sample.pdf"
  if [ -s "${dest}" ]; then
    log "PDF already present, skipping: sample.pdf"
    return 0
  fi

  tmp="$(mktemp "${dest}.XXXXXX")"
  content="BT /F1 18 Tf 72 700 Td (Fess Multimodal Search - Sample PDF) Tj ET
BT /F1 12 Tf 72 670 Td (This is a small, locally generated sample PDF used to exercise) Tj ET
BT /F1 12 Tf 72 654 Td (Fess PDF crawling and thumbnail generation for the multimodal) Tj ET
BT /F1 12 Tf 72 638 Td (search demo. It was generated entirely offline by) Tj ET
BT /F1 12 Tf 72 622 Td (bin/fetch-sample-images.sh, with no external content or network) Tj ET
BT /F1 12 Tf 72 606 Td (access required to create it.) Tj ET"
  stream_data="${content}"$'\n'
  content_len="$(printf '%s' "${stream_data}" | wc -c | tr -d ' ')"

  printf '%%PDF-1.4\n' > "${tmp}"

  off1="$(wc -c < "${tmp}" | tr -d ' ')"
  printf '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n' >> "${tmp}"

  off2="$(wc -c < "${tmp}" | tr -d ' ')"
  printf '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n' >> "${tmp}"

  off3="$(wc -c < "${tmp}" | tr -d ' ')"
  printf '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n' >> "${tmp}"

  off4="$(wc -c < "${tmp}" | tr -d ' ')"
  printf '4 0 obj\n<< /Length %s >>\nstream\n%s' "${content_len}" "${stream_data}" >> "${tmp}"
  printf 'endstream\nendobj\n' >> "${tmp}"

  off5="$(wc -c < "${tmp}" | tr -d ' ')"
  printf '5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n' >> "${tmp}"

  xref_off="$(wc -c < "${tmp}" | tr -d ' ')"
  {
    printf 'xref\n0 6\n'
    printf '0000000000 65535 f \n'
    printf '%010d 00000 n \n' "${off1}"
    printf '%010d 00000 n \n' "${off2}"
    printf '%010d 00000 n \n' "${off3}"
    printf '%010d 00000 n \n' "${off4}"
    printf '%010d 00000 n \n' "${off5}"
    printf 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%s\n%%%%EOF\n' "${xref_off}"
  } >> "${tmp}"

  mv "${tmp}" "${dest}"
  log "generated sample.pdf"
}

if generate_sample_pdf; then
  have_pdf=1
else
  warn "could not generate sample.pdf; continuing without it."
  have_pdf=0
fi

# --- Helpers for the generated HTML: pick an existing image, preferring a
# specific slug, then any downloaded image in the same category. ------------
pick_image() {
  preferred="$1"
  category="$2"
  if [ -s "${IMAGES_DIR}/${preferred}.jpg" ]; then
    echo "${preferred}"
    return 0
  fi
  for entry in "${IMAGES[@]}"; do
    IFS='|' read -r c slug _ <<< "${entry}"
    if [ "${c}" = "${category}" ] && [ -s "${IMAGES_DIR}/${slug}.jpg" ]; then
      echo "${slug}"
      return 0
    fi
  done
  # last resort: any downloaded image at all
  for entry in "${IMAGES[@]}"; do
    IFS='|' read -r _ slug _ <<< "${entry}"
    if [ -s "${IMAGES_DIR}/${slug}.jpg" ]; then
      echo "${slug}"
      return 0
    fi
  done
  return 1
}

# Body <li> list of every downloaded image in a category (skips any that
# failed to download, so pages never link to a missing file).
category_list_html() {
  category="$1"
  for entry in "${IMAGES[@]}"; do
    IFS='|' read -r c slug _ _ _ title <<< "${entry}"
    if [ "${c}" = "${category}" ] && [ -s "${IMAGES_DIR}/${slug}.jpg" ]; then
      printf '    <li><a href="../images/%s.jpg">%s</a></li>\n' "${slug}" "${title%.jpg}"
    fi
  done
}

log "Generating HTML pages ..."

animals_og="$(pick_image cat animal || true)"
write_page_animals() {
  og_src="images/cat.jpg"
  [ -n "${animals_og}" ] && og_src="images/${animals_og}.jpg"
  cat > "${PAGES_DIR}/animals.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Animal Portraits - Sample Gallery</title>
<meta name="description" content="A small set of animal photographs used to demo Fess multimodal (CLIP) and keyword search.">
<meta property="og:image" content="${BASE_URL}/${og_src}">
</head>
<body>
<h1>Animal Portraits</h1>
<p>A handful of animal photographs &mdash; cats, dogs, big cats, and more &mdash;
used to demonstrate Fess's multimodal (CLIP) image search alongside classic
keyword (BM25) search. Each photo below is also crawled and indexed
independently as its own image document; this page is a plain HTML document
with a representative thumbnail.</p>
<ul>
$(category_list_html animal)
</ul>
<p><a href="../index.html">Back to index</a></p>
</body>
</html>
EOF
}
write_page_animals

landmarks_og="$(pick_image eiffeltower building || true)"
write_page_landmarks() {
  og_src="images/eiffeltower.jpg"
  [ -n "${landmarks_og}" ] && og_src="images/${landmarks_og}.jpg"
  cat > "${PAGES_DIR}/landmarks.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>World Landmarks - Sample Gallery</title>
<meta name="description" content="A small set of landmark and nature photographs used to demo Fess multimodal (CLIP) and keyword search.">
<meta property="og:image" content="${BASE_URL}/${og_src}">
</head>
<body>
<h1>World Landmarks</h1>
<p>Famous buildings and natural landscapes &mdash; towers, castles, mountains,
and coastlines &mdash; used to demonstrate Fess's multimodal (CLIP) image
search alongside classic keyword (BM25) search.</p>
<h2>Buildings</h2>
<ul>
$(category_list_html building)
</ul>
<h2>Nature</h2>
<ul>
$(category_list_html nature)
</ul>
<p><a href="../index.html">Back to index</a></p>
</body>
</html>
EOF
}
write_page_landmarks

food_og="$(pick_image pizza food || true)"
write_page_food() {
  og_src="images/pizza.jpg"
  [ -n "${food_og}" ] && og_src="images/${food_og}.jpg"
  cat > "${PAGES_DIR}/food.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Food Gallery - Sample Gallery</title>
<meta name="description" content="A small set of food and vehicle photographs used to demo Fess multimodal (CLIP) and keyword search.">
<meta property="og:image" content="${BASE_URL}/${og_src}">
</head>
<body>
<h1>Food Gallery</h1>
<p>A small spread of food photographs, plus a few vehicles for good measure,
used to demonstrate Fess's multimodal (CLIP) image search alongside classic
keyword (BM25) search.</p>
<h2>Food</h2>
<ul>
$(category_list_html food)
</ul>
<h2>Vehicles</h2>
<ul>
$(category_list_html vehicle)
</ul>
<p><a href="../index.html">Back to index</a></p>
</body>
</html>
EOF
}
write_page_food

log "Generating index.html ..."
{
  cat << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Fess Multimodal Search - Sample Content</title>
<meta name="description" content="Sample crawlable content for the Fess multimodal (CLIP) search demo.">
</head>
<body>
<h1>Fess Multimodal Search - Sample Content</h1>
<p>This page links to every sample image, HTML page, and document in this
site so Fess's web crawler can discover all of it starting from
http://content/. See README.txt (not served) for licensing details.</p>

<h2>Pages</h2>
<ul>
<li><a href="pages/animals.html">Animal Portraits</a></li>
<li><a href="pages/landmarks.html">World Landmarks</a></li>
<li><a href="pages/food.html">Food Gallery</a></li>
</ul>
EOF

  if [ -s "${DOCS_DIR}/sample.pdf" ]; then
    printf '\n<h2>Documents</h2>\n<ul>\n<li><a href="docs/sample.pdf">Sample PDF</a></li>\n</ul>\n'
  fi

  printf '\n<h2>Images</h2>\n<ul>\n'
  for entry in "${IMAGES[@]}"; do
    IFS='|' read -r _ slug _ _ _ title <<< "${entry}"
    if [ -s "${IMAGES_DIR}/${slug}.jpg" ]; then
      printf '<li><a href="images/%s.jpg">%s</a></li>\n' "${slug}" "${title%.jpg}"
    fi
  done
  printf '</ul>\n</body>\n</html>\n'
} > "${CONTENT_DIR}/index.html"

log "Generating README.txt ..."
{
  cat << 'EOF'
Sample content for the Fess multimodal search demo
====================================================

This directory is populated by bin/fetch-sample-images.sh and served by the
"content" nginx service at http://content/, so it can be web-crawled by Fess.
Nothing in this directory is committed to git except data/content/.gitkeep;
everything else is regenerated by re-running the script.

Images
------
All photos are sourced from Wikimedia Commons (https://commons.wikimedia.org)
by their stable https://upload.wikimedia.org/... file URL, under CC0,
CC-BY, CC-BY-SA, or Public Domain terms as noted below (GFDL-only files were
deliberately avoided to keep redistribution simple). Attribution is provided
here for completeness even where the license does not strictly require it
(e.g. CC0/Public Domain).

  file          license          author/source                                 Wikimedia Commons title
  ------------  ---------------  ---------------------------------------------  ------------------------------------------------
EOF
  for entry in "${IMAGES[@]}"; do
    IFS='|' read -r _ slug license artist url title <<< "${entry}"
    status="missing (download failed or skipped)"
    [ -s "${IMAGES_DIR}/${slug}.jpg" ] && status="present"
    printf '  images/%-19s %-16s %-48s %s [%s]\n' "${slug}.jpg" "${license}" "${artist}" "${title}" "${status}"
  done
  cat << EOF

Full source URLs are in the IMAGES table at the top of bin/fetch-sample-images.sh.

HTML pages
----------
pages/animals.html, pages/landmarks.html, and pages/food.html are generated
locally (not downloaded); each has a <meta property="og:image" ...> tag
pointing at one of the images above, so Fess picks up a thumbnail for the
HTML document too. Body text is original, written for this demo.

PDF
---
EOF
  if [ "${have_pdf}" -eq 1 ]; then
    printf 'docs/sample.pdf is a minimal, locally generated PDF (no external\n'
    printf 'content, no network access) used to exercise PDF crawling and\n'
    printf 'thumbnailing.\n'
  else
    printf 'docs/sample.pdf could not be generated on this run; skipped.\n'
    printf 'The web crawl still has plenty of images and HTML pages to exercise.\n'
  fi
  cat << 'EOF'

index.html
----------
Lists every image/page/doc that is actually present on disk, so Fess's web
crawler can discover everything by following links from http://content/.

Re-running this script
-----------------------
Safe to re-run at any time: already-downloaded images are left alone, and a
failed download only prints a WARNING and moves on (it does not abort the
run). Delete a file under images/ and re-run to re-fetch it.
EOF
} > "${CONTENT_DIR}/README.txt"

log "Done. Content dir: ${CONTENT_DIR}"
log "  images: $(find "${IMAGES_DIR}" -name '*.jpg' -type f | wc -l | tr -d ' ')"
log "  pages:  $(find "${PAGES_DIR}" -name '*.html' -type f | wc -l | tr -d ' ')"
log "  docs:   $(find "${DOCS_DIR}" -type f | wc -l | tr -d ' ')"
log "  total size: $(du -sh "${CONTENT_DIR}" 2>/dev/null | cut -f1)"
