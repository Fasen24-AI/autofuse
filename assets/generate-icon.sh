#!/bin/bash
# Generate AutoFuse.icns from a 1024px PNG
# Usage: ./generate-icon.sh icon.png
SRC="${1:-AutoFuse.png}"
[ ! -f "$SRC" ] && { echo "Missing $SRC"; exit 1; }
OUT="AutoFuse.iconset"
rm -rf "$OUT" && mkdir "$OUT"
for sz in 16 32 64 128 256 512 1024; do
    sips -z "$sz" "$sz" "$SRC" --out "$OUT/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$SRC" --out "$OUT/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$OUT"
rm -rf "$OUT"
echo "Created AutoFuse.icns"
