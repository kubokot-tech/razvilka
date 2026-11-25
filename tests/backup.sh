#!/bin/sh
# Проверяем файловое восстановление без маршрутизатора и привилегий.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
workdir=$(mktemp -d "${TMPDIR:-/tmp}/razvilka-backup.XXXXXX")
trap 'rm -rf "$workdir"' EXIT
DIR=$workdir/router
mkdir -p "$DIR/lists"
# Загружаем штатные настройки по умолчанию, затем подменяем только операции с роутером.
sed "s|^DIR=/opt/razvilka$|DIR=$DIR|" "$ROOT/src/lib/core.sh" > "$workdir/core.sh"
. "$workdir/core.sh"
. "$ROOT/src/lib/devices.sh"
. "$ROOT/src/lib/ipv6.sh"
TAR_BIN=tar
. "$ROOT/src/lib/backup.sh"
LOG=$workdir/log
log() { printf '%s\n' "$*" >> "$LOG"; }
device_apply() { printf '%s\n' "$VPN_IF" > "$workdir/applied"; }
ipv6_block_on() { :; }
ai_is_on() { [ -f "$DIR/ai_protect" ]; }
make_stub() { :; }
flush_flows() { :; }
RZ_TEST_LIGHTTPD=true
RZ_TEST_WEB_INIT=$workdir/web
export RZ_TEST_WEB_INIT RZ_TEST_LIGHTTPD
cat > "$RZ_TEST_WEB_INIT" <<EOF
#!/bin/sh
if [ -f "$workdir/fail-web" ]; then rm "$workdir/fail-web"; exit 1; fi
echo web-restarted >> "$workdir/actions"
EOF
chmod +x "$RZ_TEST_WEB_INIT"
printf 'VPN_IF="wg-old"\nWEB_PORT="98"\n' > "$DIR/razvilka.conf"
printf 'direct\n' > "$DIR/failmode"
printf 'admin:old-pass\n' > "$DIR/web.users"
printf 'oldtoken\n' > "$DIR/csrf.token"
printf 'example.com\n' > "$DIR/lists/direct.list"
: > "$DIR/lists/vpn.list"
: > "$DIR/kill-allow.presets"
cp "$ROOT/src/lighttpd.conf" "$DIR/lighttpd.conf.in"
printf 'original lighttpd conf\n' > "$DIR/lighttpd.conf"
load_router_config
archive=$(backup_settings)
original=$workdir/original
mkdir "$original"
tar xzf "$archive" -C "$original"

reject() {
    if restore_settings "$1" >/dev/null 2>&1; then
        echo "unexpected restore success: $1" >&2
        exit 1
    fi
    cmp -s "$DIR/web.users" "$original/web.users"
    cmp -s "$DIR/razvilka.conf" "$original/razvilka.conf"
    [ ! -f "$workdir/applied" ]
}
tar czf "$workdir/incomplete" -C "$original" web.users
reject "$workdir/incomplete"
# Из архива пропал необязательный файл, указанный в manifest.
mkdir "$workdir/stage"
cp -R "$original/." "$workdir/stage/"
rm "$workdir/stage/kill-allow.presets"
# Полные старые архивы до введения manifest остаются читаемыми.
create_archive() (
    dest=$1; cd "$workdir/stage"; shift
    for entry in $BACKUP_FILES; do [ ! -e "$entry" ] || set -- "$@" "$entry"; done
    tar czf "$dest" "$@"
)
create_archive "$workdir/missing-entry" manifest
reject "$workdir/missing-entry"
ln -s "$original/kill-allow.presets" "$workdir/stage/kill-allow.presets"
create_archive "$workdir/link"
reject "$workdir/link"
rm "$workdir/stage/kill-allow.presets"
ln "$workdir/stage/web.users" "$workdir/stage/kill-allow.presets"
create_archive "$workdir/hardlink"
reject "$workdir/hardlink"
rm "$workdir/stage/kill-allow.presets"
printf 'PATH="/tmp"\n' >> "$workdir/stage/razvilka.conf"
create_archive "$workdir/unknown-key"
reject "$workdir/unknown-key"
cp "$original/razvilka.conf" "$workdir/stage/razvilka.conf"
printf 'VPN_RESTART="/bin/false"\n' >> "$workdir/stage/razvilka.conf"
create_archive "$workdir/foreign-command"
reject "$workdir/foreign-command"

printf 'VPN_IF="wg-new"\nWEB_PORT="99"\n' > "$workdir/stage/razvilka.conf"
printf 'admin:new-pass\n' > "$workdir/stage/web.users"
chmod 644 "$workdir/stage/web.users" "$workdir/stage/csrf.token"
create_archive "$workdir/valid"
touch "$workdir/fail-web"
if restore_settings "$workdir/valid"; then echo 'missing restart failure' >&2; exit 1; fi
cmp -s "$DIR/web.users" "$original/web.users"
cmp -s "$DIR/razvilka.conf" "$original/razvilka.conf"
grep -qx 'wg-old' "$workdir/applied"
grep -qx 'original lighttpd conf' "$DIR/lighttpd.conf"
restore_settings "$workdir/valid"
grep -qx 'wg-new' "$workdir/applied"
grep -Fq '192.168.1.1:99' "$DIR/lighttpd.conf"
cmp -s "$DIR/web.users" "$workdir/stage/web.users"
for secret in web.users csrf.token; do
    [ -n "$(find "$DIR/$secret" -perm 600 -print)" ]
done
echo 'PASS: archive validation, private credentials, port and interface restore, checked rollback'
