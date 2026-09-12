#!/usr/bin/env bash
# Rebuilds the Magic price-history database from MTGJSON on this host.
#
# MTGJSON's smallest price artifact is a 1.2 GB JSON document keyed by its own
# UUIDs; slice_prices.py streams it once and joins it to Scryfall ids, which is
# why this runs here rather than shipping a 1.8 GB file over a home connection.
set -euo pipefail
DIR=/home/zixen/arcanum
RAW=$DIR/data/mtgjson
OUT=$DIR/data/prices.db
mkdir -p "$RAW"
cd "$RAW"
for f in AllIdentifiers.json.gz AllPrices.json.gz; do
  if [ ! -s "$f" ]; then
    echo "downloading $f at $(date -u +%FT%TZ)"
    curl -fsSL --retry 3 -o "$f.part" "https://mtgjson.com/api/v5/$f"
    mv "$f.part" "$f"
  fi
  echo "$f: $(stat -c%s "$f") bytes"
done
echo "slicing at $(date -u +%FT%TZ)"
python3 "$DIR/slice_prices.py" --dir "$RAW" --out "$OUT.new"
mv "$OUT.new" "$OUT"
echo "wrote $OUT ($(stat -c%s "$OUT") bytes) at $(date -u +%FT%TZ)"
echo "restart arcanum-sync.service to serve it"
