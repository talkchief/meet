#!/usr/bin/env bash
# Rebrands the stock Jitsi Meet web root as TalkChief Cowork. Runs at image build.
set -euo pipefail
ROOT="$1"; B="$2"
NAME="TalkChief Cowork"

# Static assets: every logo/icon slot points at TalkChief artwork.
install -m 0644 "$B/images/talkchief-cowork-white.png" "$ROOT/images/talkchief-cowork-white.png"
install -m 0644 "$B/images/talkchief-cowork-white.png" "$ROOT/images/jitsilogo.png"
install -m 0644 "$B/images/talkchief-icon-192.png"     "$ROOT/images/logo-deep-linking.png"
install -m 0644 "$B/images/talkchief-icon-192.png"     "$ROOT/images/logo-deep-linking-mobile.png"
install -m 0644 "$B/images/talkchief-icon-192.png"     "$ROOT/images/talkchief-icon-192.png"
install -m 0644 "$B/images/apple-touch-icon.png"       "$ROOT/images/apple-touch-icon.png"
install -m 0644 "$B/images/favicon.ico"                "$ROOT/favicon.ico"
install -m 0644 "$B/images/favicon.ico"                "$ROOT/images/favicon.ico"
cp "$B/images/talkchief-cowork.svg" "$ROOT/images/watermark.svg"
# favicon.svg is referenced by index.html; replace it with an SVG wrapper of the PNG icon.
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><image href="images/talkchief-icon-192.png" width="192" height="192"/></svg>\n' > "$ROOT/images/favicon.svg"
install -m 0644 "$B/title.html" "$ROOT/title.html"

# Visible wording: lang bundles, static pages, PWA manifest.
for f in "$ROOT"/lang/*.json "$ROOT"/manifest.json; do
  [ -f "$f" ] || continue
  sed -i -E \
    -e "s/Jitsi Meet/${NAME}/g" \
    -e "s/Jitsi as a Service/${NAME}/g" \
    -e "s/Jitsi Videobridge/${NAME}/g" \
    -e "s/(^|[^/.a-zA-Z-])Jitsi([^/.a-zA-Z-]|$)/\1${NAME}\2/g" \
    "$f"
done
# manifest identity
sed -i -E 's/"org\.jitsi\.meet"/"io.talkchief.cowork.meet"/g' "$ROOT/manifest.json"

# Brand CSS layered after the stock stylesheet.
install -m 0644 "$B/talkchief.css" "$ROOT/css/talkchief.css"
grep -q 'css/talkchief.css' "$ROOT/index.html" || \
  sed -i 's#</head>#<link rel="stylesheet" href="css/talkchief.css"></head>#' "$ROOT/index.html"
echo "branding applied"
