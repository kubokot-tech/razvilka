#!/bin/sh
# Собирает монолит и самодостаточный установщик dist/razvilka-setup.sh.
set -eu
cd "$(dirname "$0")"
VERSION=${VERSION:-$(date +%Y.%m.%d-%H%M)}
case "$VERSION" in ''|*[!a-zA-Z0-9._-]*) echo 'Недопустимая VERSION' >&2; exit 1 ;; esac
mkdir -p dist
tmp=$(mktemp -d dist/.build.XXXXXXXX)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
cat src/lib/core.sh src/lib/ipv6.sh src/lib/ai.sh src/lib/devices.sh src/lib/lists.sh src/lib/kill.sh src/lib/web.sh src/lib/neighbors.sh src/lib/backup.sh src/lib/main.sh > "$tmp/razvilka.sh"
for f in setup.sh install.sh src/lib/*.sh "$tmp/razvilka.sh" src/www/*.sh src/init/* src/cron-*; do sh -n "$f"; done
cp -R src "$tmp/src"
cp "$tmp/razvilka.sh" "$tmp/src/razvilka.sh"
COPYFILE_DISABLE=1 tar czf "$tmp/payload.tar.gz" --no-xattrs -C "$tmp/src" .
base64 < "$tmp/payload.tar.gz" > "$tmp/base64"
fold -w 76 < "$tmp/base64" > "$tmp/wrapped"
awk -v ver="$VERSION" -v data="$tmp/wrapped" '
    /^@PAYLOAD@$/ { print "payload() { cat <<\047__RAZVILKA_PAYLOAD__\047"; while ((getline line < data) > 0) print line; print "__RAZVILKA_PAYLOAD__"; print "}"; next }
    { gsub(/@VERSION@/, ver); print }' setup.sh > "$tmp/installer"
sh -n "$tmp/installer"
chmod 755 "$tmp/installer"
mv -f "$tmp/razvilka.sh" src/razvilka.sh
mv -f "$tmp/installer" dist/razvilka-setup.sh
echo "dist/razvilka-setup.sh  версия $VERSION  $(wc -c < dist/razvilka-setup.sh) байт"
