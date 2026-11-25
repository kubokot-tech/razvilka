#!/bin/bash
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
trap 'exit 1' HUP INT TERM
export T
router=$T/opt/razvilka
bin=$T/opt/bin
mkdir -p "$router" "$bin" "$T/opt/etc/init.d" "$T/opt/tmp" "$T/opt/sbin" "$T/opt/root" "$T/sys/class/net/tun0" "$T/sys/class/net/eth0" "$T/proc/net"
touch "$T/proc/net/route"
sed -e "s|/opt|$T/opt|g" -e "s|/sys/|$T/sys/|g" -e "s|/proc/|$T/proc/|g" \
    -e 's|^@PAYLOAD@$|payload() { COPYFILE_DISABLE=1 tar czf - -C "$T/package" . \| base64; }|' "$ROOT/setup.sh" > "$T/setup.sh"
cp -R "$ROOT/src" "$T/package"
# Все команды, читающие или меняющие состояние роутера, работают только с этим каталогом.
for cmd in id ip ip6tables ping ndmc flock nslookup sleep; do
    printf '#!/bin/sh\nexit 0\n' > "$bin/$cmd"
done
printf '#!/bin/sh\necho 0\n' > "$bin/id"
printf '#!/bin/sh\nexit 1\n' > "$bin/ip6tables"
printf '#!/bin/sh\necho "tcp 0 0 192.168.1.1:98 0.0.0.0:* LISTEN"\n' > "$bin/netstat"
printf '#!/bin/sh\nexit 0\n' > "$T/opt/sbin/lighttpd"
sed -n 's/^PKGS="\(.*\)"/\1/p' "$ROOT/setup.sh" | tr ' ' '\n' > "$T/pkgs"
echo conntrack >> "$T/pkgs"
cat > "$bin/opkg" <<'STUB'
#!/bin/sh
case "$1" in
    list-installed) sed 's/$/ - mock/' "$T/pkgs" ;;
    *) echo "$*" >> "$T/opkg-writes"; exit 1 ;;
esac
STUB
chmod +x "$bin/"* "$T/opt/sbin/lighttpd"
cat > "$T/package/razvilka.sh" <<'STUB'
#!/bin/sh
# new-runtime
d=$T/opt/razvilka
case "$1" in
    start) [ ! -f "$T/fail-start" ] || exit 1; touch "$d/enabled" ;;
    stop) rm -f "$d/enabled" ;;
    status-kv) echo 'rule=1' ;;
    stub) echo stub > "$d/stub/index.html" ;;
    update) echo '192.0.2.0/24' > "$d/ru.cidr" ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$T/package/init/S81razvilka-web"
printf '#!/bin/sh\necho unrelated >> "$T/bird-actions"\n' > "$T/opt/etc/init.d/S70bird"
chmod +x "$T/opt/etc/init.d/S70bird"
echo unrelated > "$T/opt/etc/bird.conf"
install_router() { sh "$T/setup.sh" install --yes --vpn-if tun0 --isp-if eth0 "$@"; }

install_router --no-hostname --web-pass sample > "$T/install.out"
[ -f "$router/ipv6_block" ]
[ -s "$router/lighttpd.conf.in" ]
[ -x "$router/www/log.sh" ]
cmp "$ROOT/src/lib/journal.awk" "$router/journal.awk"
cmp "$ROOT/src/www/journal.css" "$router/www/journal.css"
[ -f "$router/enabled" ]
grep -qx unrelated "$T/opt/etc/bird.conf"
[ -x "$T/opt/etc/init.d/S70bird" ]
[ ! -e "$T/bird-actions" ]
[ ! -e "$T/opkg-writes" ]
rm -f "$router/ipv6_block"
mkdir -p "$router/backups"
echo history > "$router/backups/previous.tar.gz"
install_router > "$T/reinstall.out"
[ ! -e "$router/ipv6_block" ]
grep -qx 'HOSTNAME_LAN=""' "$router/razvilka.conf"
grep -qx 'LAN_IF="br+"' "$router/razvilka.conf"
cp "$router/razvilka.conf" "$T/old.conf"
sed -e '/# new-runtime/d' -e 's/\[ ! -f "$T\/fail-start" \] || exit 1; //' "$router/razvilka.sh" > "$T/old.sh"
cp "$T/old.sh" "$router/razvilka.sh"
touch "$T/fail-start"
if install_router --web-port 99 > "$T/failure.out" 2>&1; then echo 'Failed upgrade reported success' >&2; exit 1; fi
cmp "$T/old.sh" "$router/razvilka.sh"
cmp "$T/old.conf" "$router/razvilka.conf"
[ -f "$router/enabled" ]
[ ! -e "$router/ipv6_block" ]
grep -qx history "$router/backups/previous.tar.gz"
# Сбой до остановки старого сервиса тоже не должен менять файлы.
rm "$T/fail-start" "$T/package/www/backup.sh"
if install_router > "$T/missing.out" 2>&1; then echo 'Incomplete payload was accepted' >&2; exit 1; fi
cmp "$T/old.sh" "$router/razvilka.sh"
cmp "$T/old.conf" "$router/razvilka.conf"
[ -f "$router/enabled" ]
cp "$ROOT/src/www/backup.sh" "$T/package/www/backup.sh"
mkdir -p "$T/opt/Bird4Static/lists"
echo example.org > "$T/opt/Bird4Static/lists/user-vpn.list"
install_router > "$T/bird-migration.out"
grep -qx example.org "$router/lists/vpn.list"
[ ! -d "$T/opt/Bird4Static" ]
grep -qx unrelated "$T/opt/etc/bird.conf"
[ -x "$T/opt/etc/init.d/S70bird" ]
[ ! -e "$T/bird-actions" ]
[ ! -e "$T/opkg-writes" ]
sh "$T/setup.sh" uninstall > "$T/uninstall.out"
grep -q 'удалено; списки и настройки оставлены' "$T/uninstall.out"
grep -qx history "$router/backups/previous.tar.gz"
[ -f "$router/enabled" ]
[ ! -e "$router/razvilka.sh" ]
sh "$T/setup.sh" uninstall --purge > "$T/purge.out"
[ ! -e "$router" ]
echo 'Installer upgrade, rollback, preservation and purge checks passed'
