#!/bin/sh
# Собирает самодостаточный установщик dist/razvilka-setup.sh (исходники внутри, base64 tar.gz)
set -e
cd "$(dirname "$0")"
VERSION=${VERSION:-$(date +%Y.%m.%d-%H%M)}
for f in setup.sh src/razvilka.sh src/www/index.sh src/init/* src/cron-*; do sh -n "$f"; done
mkdir -p dist
B64=$(COPYFILE_DISABLE=1 tar czf - --no-xattrs -C src . 2>/dev/null | base64 | fold -w 76)
printf '%s\n' "$B64" > dist/.b64
awk -v ver="$VERSION" '
    /^@PAYLOAD@$/ { print "payload() { cat <<'"'"'__RAZVILKA_PAYLOAD__'"'"'"; while ((getline l < "dist/.b64") > 0) print l; print "__RAZVILKA_PAYLOAD__"; print "}"; next }
    { gsub(/@VERSION@/, ver); print }' setup.sh > dist/razvilka-setup.sh
rm -f dist/.b64
chmod 755 dist/razvilka-setup.sh
sh -n dist/razvilka-setup.sh
echo "dist/razvilka-setup.sh  версия $VERSION  $(wc -c < dist/razvilka-setup.sh) байт"
