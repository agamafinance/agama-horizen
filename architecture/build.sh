#!/usr/bin/env bash
# Render index.html to PDF with headless Chrome, then stamp the running
# header and footer bands onto every page.
#
#   ./build.sh                       -> ./Agama - Confidential Credit on Horizen.pdf
#   ./build.sh /path/to/output.pdf   -> that path
#
# Two passes are needed because Chrome clamps position:fixed elements to the
# page content box: a running band drawn from index.html can never reach into
# the page margins. So page-furniture.html is rendered once as a single A4
# page and merged under every page of the body with pypdf.
#
# WeasyPrint is not used: the local install is missing its native libraries.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$DIR/../Agama x Horizen - Technical Architecture.pdf}"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || CHROME="/Applications/Chromium.app/Contents/MacOS/Chromium"
[ -x "$CHROME" ] || { echo "Chrome not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {  # render <html file> <pdf file>
  "$CHROME" \
    --headless \
    --disable-gpu \
    --no-sandbox \
    --no-first-run \
    --user-data-dir="$TMP/profile-$2" \
    --no-pdf-header-footer \
    --run-all-compositor-stages-before-draw \
    --virtual-time-budget=15000 \
    --print-to-pdf="$TMP/$2" \
    "file://$DIR/$1" >/dev/null 2>&1 &
  local pid=$!
  # Headless Chrome writes the PDF and then sometimes fails to exit, so wait
  # for the file to settle rather than for the process.
  local waited=0
  while [ $waited -lt 90 ]; do
    if [ -s "$TMP/$2" ]; then
      local a b
      a=$(wc -c < "$TMP/$2"); sleep 1; b=$(wc -c < "$TMP/$2")
      [ "$a" = "$b" ] && break
    fi
    sleep 1; waited=$((waited + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -s "$TMP/$2" ] || { echo "render failed: $1" >&2; exit 1; }
}

render index.html body.pdf
render page-furniture.html furniture.pdf

python3 - "$TMP/body.pdf" "$TMP/furniture.pdf" "$OUT" <<'PY'
import sys
from pypdf import PdfReader, PdfWriter
from pypdf.annotations import Link

body, furniture, out = sys.argv[1:4]
band_page = PdfReader(furniture).pages[0]
reader = PdfReader(body)
writer = PdfWriter()

for page in reader.pages:
    page.merge_page(band_page)     # bands paint over the (empty) page margins
    writer.add_page(page)

# Whether merge_page carries annotations across has varied between pypdf
# releases, and a link that is painted but dead is worse than no link. Collect
# the band's targets, then add only the ones a page does not already carry, so
# this works either way and never doubles them up.
def links_of(page):
    out = []
    for annot in page.get("/Annots", []) or []:
        a = annot.get_object()
        uri = (a.get("/A") or {}).get("/URI")
        if a.get("/Subtype") == "/Link" and uri:
            out.append((tuple(round(float(x), 1) for x in a["/Rect"]), str(uri)))
    return out

band_links = links_of(band_page)
added = 0
for i, wpage in enumerate(writer.pages):
    present = set(links_of(wpage))
    for rect, uri in band_links:
        if (rect, uri) not in present:
            writer.add_annotation(page_number=i, annotation=Link(rect=rect, url=uri))
            added += 1

with open(out, "wb") as fh:
    writer.write(fh)
print(f"{len(reader.pages)} pages, {len(band_links)} band link(s), {added} re-added")
PY

echo "Wrote: $OUT"
command -v pdfinfo >/dev/null 2>&1 && pdfinfo "$OUT" | grep -E '^(Pages|Page size)'
exit 0
