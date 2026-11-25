#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
trap 'exit 1' HUP INT TERM
dist=dist/razvilka-setup.sh
sh -n "$dist"
mkdir "$T/src"
awk '/^payload\(\) \{/{p=1;next} p && /^__RAZVILKA_PAYLOAD__$/{exit} p{print}' "$dist" > "$T/base64"
if base64 -d </dev/null >/dev/null 2>&1; then decode=-d; else decode=-D; fi
base64 "$decode" < "$T/base64" > "$T/payload.tar.gz"
tar xzf "$T/payload.tar.gz" -C "$T/src"
diff -ru src "$T/src"
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$dist")
case "$version" in ''|*[!a-zA-Z0-9._-]*) exit 1 ;; esac
sed "s/@VERSION@/$version/g" setup.sh > "$T/expected"
awk '
    /^payload\(\) \{ cat <<\047__RAZVILKA_PAYLOAD__\047$/ {p=1; print "@PAYLOAD@"; next}
    p && /^__RAZVILKA_PAYLOAD__$/ {if ((getline) <= 0 || $0 != "}") exit 1; p=0; next}
    !p {print}
    END {if (p) exit 1}
' "$dist" > "$T/actual"
diff -u "$T/expected" "$T/actual"
echo 'Committed dist payload and installer wrapper match sources'
