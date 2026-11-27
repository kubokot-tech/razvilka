#!/bin/sh
# Razvilka — установщик для роутеров Keenetic и Netcraze с Entware.
# Весь иностранный трафик через VPN, российский напрямую, kill switch с заглушкой, веб-морда.
#
#   sh razvilka-setup.sh install   [параметры]   поставить / обновить (повторный запуск безопасен)
#   sh razvilka-setup.sh uninstall [--purge]     удалить (--purge — и списки/настройки)
#   sh razvilka-setup.sh status
#
# Одной строкой с GitHub:
#   curl -fsSL https://raw.githubusercontent.com/kubokot-tech/razvilka/main/dist/razvilka-setup.sh | sh -s -- install
#
# Параметры install (всё определяется само; задавать — если автоопределение ошиблось):
#   --vpn-if IF         основной VPN-интерфейс (opkgtun0, nwg0, ...)
#   --vpn2-if IF        дополнительный VPN для отдельных устройств; --no-vpn2 — выключить
#   --vpn2-server IP    адрес сервера дополнительного VPN (можно несколько раз)
#   --vpn2-process NAME процесс дополнительного VPN для определения сервера
#   --isp-if IF         интерфейс провайдера (eth3, ppp0, ...)
#   --vpn-server IP     адрес VPN-сервера, если не определяется сам (можно несколько раз)
#   --vpn-process NAME  имя процесса VPN-клиента — по его соединениям определяется адрес сервера
#   --vpn-restart CMD   команда перезапуска VPN для кнопки в веб-морде
#   --web-pass PASS     пароль веб-морды (логин admin); без него — спросит или оставит прежний
#   --web-port N        порт веб-морды (98)          --stub-port N   порт заглушки (8098)
#   --hostname NAME     имя веб-морды в DNS роутера (razvilka.lan), --no-hostname — не создавать
#   --alias-ip IP       отдельный адрес для неё на 80-м порту (по умолчанию .254 сети, если свободен)
#   --failmode direct|soft|kill  поведение при падении туннеля (direct)
#   --keep-bird         не удалять Bird4Static/web4static (по умолчанию удаляются: списки переносятся)
#   --yes               не задавать вопросов
#
# Файл самодостаточный: исходники пакета лежат внутри (в конце, base64 tar.gz).

set -u
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root

DIR=/opt/razvilka
VERSION="2026.11.27-1434"
PKGS="ip-full iptables ipset curl bind-dig cron flock tar lighttpd lighttpd-mod-cgi lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-rewrite lighttpd-mod-setenv"
OPT_PKGS="conntrack"     # необязательные: без них работает, но хуже (conntrack — сброс соединений при переключении)
REPO_HOSTS="bin.entware.net"

c_ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[1;36m•\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()    { printf '\033[1;31m✗ %s\033[0m\n' "$*"; exit 1; }

ACTION=${1:-install}; [ $# -gt 0 ] && shift
VPN_IF= ; ISP_IF= ; VPN_SERVERS= ; VPN_RESTART= ; VPN_PROCESS= ; HOSTNAME_LAN= ; ALIAS_IP= ; WEB_PASS= ; WEB_PORT= ; STUB_PORT=
VPN2_IF= ; VPN2_SERVERS= ; VPN2_PROCESS=
CONTACT= ; FAILMODE= ; KEEP_BIRD=0 ; YES=0 ; PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --vpn-if) VPN_IF=$2; shift ;;
        --vpn2-if) VPN2_IF=$2; shift ;;
        --no-vpn2) VPN2_IF=none ;;
        --vpn2-server) VPN2_SERVERS="$VPN2_SERVERS $2"; shift ;;
        --vpn2-process) VPN2_PROCESS=$2; shift ;;
        --isp-if) ISP_IF=$2; shift ;;
        --vpn-server) VPN_SERVERS="$VPN_SERVERS $2"; shift ;;
        --vpn-restart) VPN_RESTART=$2; shift ;;
        --vpn-process) VPN_PROCESS=$2; shift ;;
        --hostname) HOSTNAME_LAN=$2; shift ;;
        --alias-ip) ALIAS_IP=$2; shift ;;
        --no-hostname) HOSTNAME_LAN=none ;;
        --web-pass) WEB_PASS=$2; shift ;;
        --web-port) WEB_PORT=$2; shift ;;
        --stub-port) STUB_PORT=$2; shift ;;
        --contact) CONTACT=$2; shift ;;
        --failmode) FAILMODE=$2; shift ;;
        --keep-bird) KEEP_BIRD=1 ;;
        --yes|-y) YES=1 ;;
        --purge) PURGE=1 ;;
        -h|--help) echo "см. https://github.com/kubokot-tech/razvilka"; exit 0 ;;
        *) die "неизвестный параметр: $1" ;;
    esac
    shift
done

TTY=; [ $YES = 0 ] && [ -r /dev/tty ] && (exec </dev/tty) 2>/dev/null && TTY=/dev/tty
ask() {  # ask "вопрос" "по умолчанию" -> ответ в $REPLY
    REPLY=$2
    [ -n "$TTY" ] || return 0
    printf '%s [%s]: ' "$1" "$2" > /dev/tty
    read -r REPLY < /dev/tty || REPLY=$2
    [ -z "$REPLY" ] && REPLY=$2
    return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- автоопределение (работает и без ip-full: через /proc и /sys) ----------

default_route_ifaces() { awk 'NR>1 && $2=="00000000" && $8=="00000000" {print $1}' /proc/net/route; }
iface_gw() {  # шлюз интерфейса из /proc/net/route (hex little-endian -> a.b.c.d)
    awk -v iface="$1" '
        function digit(pos) { return index("0123456789ABCDEF", toupper(substr($3, pos, 1))) - 1 }
        function octet(pos) { return 16 * digit(pos) + digit(pos + 1) }
        NR > 1 && $1 == iface && $2 == "00000000" && $8 == "00000000" {
            printf "%d.%d.%d.%d\n", octet(7), octet(5), octet(3), octet(1)
            exit
        }' /proc/net/route
}
vpn_candidates() { ls /sys/class/net 2>/dev/null | grep -E '^(opkgtun|nwg|wg|awg|tun|ovpn)[0-9]+$'; }
iface_ok() { ping -I "$1" -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -I "$1" -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; }

detect_vpn() {
    [ -n "$VPN_IF" ] && return 0
    # повторная установка: прежний интерфейс из конфига важнее автоопределения —
    # при упавшем туннеле живого кандидата нет, и выбрался бы первый попавшийся
    prev=$(sed -n 's/^VPN_IF="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$DIR/razvilka.conf" 2>/dev/null | tail -1)
    [ -n "$prev" ] && [ -d "/sys/class/net/$prev" ] && { VPN_IF=$prev; return 0; }
    for i in $(vpn_candidates); do iface_ok "$i" && { VPN_IF=$i; return 0; }; done
    VPN_IF=$(vpn_candidates | head -1)
}
detect_isp() {
    [ -n "$ISP_IF" ] && return 0
    prev=$(sed -n 's/^ISP_IF="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$DIR/razvilka.conf" 2>/dev/null | tail -1)
    [ -n "$prev" ] && [ -d "/sys/class/net/$prev" ] && { ISP_IF=$prev; return 0; }
    ISP_IF=$(default_route_ifaces | grep -vxF "${VPN_IF:-none}" | grep -vE '^(opkgtun|nwg|wg|awg|tun|ovpn)' | head -1)
}
detect_lan_ip() {
    LAN_IP=$(ip -4 addr show br0 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
    [ -n "$LAN_IP" ] || LAN_IP=$(ifconfig br0 2>/dev/null | awk '/inet addr:/{sub("addr:","",$2); print $2; exit}')
    [ -n "$LAN_IP" ] || LAN_IP=192.168.1.1
}
# init-скрипт VPN-клиента в Entware: S*vpn*, S*awg*, S*wg*, S*sing-box*, S*xray*, S*openconnect* ...
vpn_init_scripts() {
    ls /opt/etc/init.d/ 2>/dev/null | grep -E '^S[0-9]+' | grep -iE 'vpn|awg|wg|wireguard|sing-?box|xray|v2ray|openconnect|tun2|hev|ss-|shadowsocks|trojan|hysteria' \
        | grep -viE 'razvilka|foreign-vpn'
}
detect_restart() {
    s=$(vpn_init_scripts)
    [ "$(echo "$s" | grep -c .)" = 1 ] || s=
    [ -z "$VPN_RESTART" ] && [ -n "$s" ] && VPN_RESTART="/opt/etc/init.d/$s restart"
    # имя процесса клиента: из имени init-скрипта (S99foo -> foo), если такой процесс запущен
    if [ -z "$VPN_PROCESS" ] && [ -n "$s" ]; then
        n=$(echo "$s" | sed -E 's/^S[0-9]+//')
        pidof "$n" >/dev/null 2>&1 && VPN_PROCESS=$n
    fi
    return 0
}

resolve_host() {  # busybox nslookup: в строке Address после IP может идти имя — берём только IPv4
    nslookup "$1" 2>/dev/null | awk '/^Name:/{n=1} n && /^Address/' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
}

# Провайдер может душить зарубежные хостинги (Entware, GitHub) — на время установки
# пускаем их через VPN. Без ip-full маршрут ставится средствами прошивки (ndmc).
TMP_ROUTES=
ndm_name() {  # linux-имя -> имя интерфейса в прошивке Keenetic
    ndmc -c "show interface" 2>/dev/null | awk -v want="$1" '
        /^ *id: /{id=$2} /^ *interface-name: /{if ($2==want) {print id; exit}}'
}
temp_routes_on() {
    [ -n "$VPN_IF" ] && iface_ok "$VPN_IF" || return 0
    for h in $REPO_HOSTS; do
        for ip in $(resolve_host "$h"); do
            if have ip; then ip route add "$ip/32" dev "$VPN_IF" 2>/dev/null && TMP_ROUTES="$TMP_ROUTES ip:$ip"
            else
                n=$(ndm_name "$VPN_IF"); [ -n "$n" ] && ndmc -c "ip route $ip 255.255.255.255 $n auto" >/dev/null 2>&1 && TMP_ROUTES="$TMP_ROUTES ndm:$ip:$n"
            fi
        done
    done
    [ -n "$TMP_ROUTES" ] && c_info "репозиторий Entware временно через VPN (провайдер может его душить)"
    return 0
}
temp_routes_off() {
    for r in $TMP_ROUTES; do
        case "$r" in
            ip:*)  ip route del "${r#ip:}/32" dev "$VPN_IF" 2>/dev/null ;;
            ndm:*) x=${r#ndm:}; ndmc -c "no ip route ${x%%:*} 255.255.255.255 ${x#*:}" >/dev/null 2>&1 ;;
        esac
    done
    TMP_ROUTES=
}
SRC=
INSTALL_TRANSACTION=0
RESTORE_UNINSTALL_PREFS=0
installer_exit() {
    result=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [ "$INSTALL_TRANSACTION" = 1 ]; then
        rollback_install || { c_warn "откат не завершён; сохранены файлы установки в $SRC"; SRC=; }
    fi
    if [ "$RESTORE_UNINSTALL_PREFS" = 1 ]; then
        for flag in $SAVED_FLAGS; do touch "$DIR/$flag" || result=1; done
    fi
    temp_routes_off
    [ -z "$SRC" ] || rm -rf "$SRC"
    exit "$result"
}
trap installer_exit EXIT
trap 'exit 1' HUP INT TERM

# ---------- распаковка исходников из этого файла ----------

unpack() {
    SRC=$(mktemp -d /opt/tmp/razvilka-src.XXXXXXXX) || die 'нет места для распаковки'
    payload | base64 -d | tar xzf - -C "$SRC" || die "не удалось распаковать пакет"
}

# ---------- переезд со старого имени (foreign-vpn -> Razvilka) ----------

migrate_old_name() {
    O=/opt/foreign-vpn
    [ -d "$O" ] || [ -f /opt/etc/lighttpd/conf.d/85-fvpn.conf ] || return 0
    c_info "переношу прежнюю установку foreign-vpn в Razvilka"
    LEGACY_MIGRATION=1
    [ ! -f "$O/enabled" ] || LEGACY_ENABLED=1
    if [ -x "$O/fvpn.sh" ]; then
        "$O/fvpn.sh" stop >/dev/null 2>&1
        [ ! -f "$O/enabled" ] || die 'не удалось остановить foreign-vpn'
    fi
    [ ! -x /opt/etc/init.d/S81foreign-vpn-web ] || /opt/etc/init.d/S81foreign-vpn-web stop >/dev/null 2>&1 || die 'не удалось остановить панель foreign-vpn'
    if [ -f /opt/etc/lighttpd/conf.d/85-fvpn.conf ]; then
        LEGACY_SHARED_WEB=1
        save_original /opt/etc/lighttpd/conf.d/85-fvpn.conf
        rm -f /opt/etc/lighttpd/conf.d/85-fvpn.conf || die 'не удалось отключить конфигурацию foreign-vpn'
        [ ! -x /opt/etc/init.d/S80lighttpd ] || /opt/etc/init.d/S80lighttpd restart 8>&- || die 'не удалось обновить общий lighttpd'
    fi
    if [ -d "$O" ]; then
        mkdir -p "$DIR/lists" || die 'не удалось создать каталог списков'
        for f in lists/direct.list lists/vpn.list contact.txt web.users failmode ru.cidr asn-names; do
            if [ -f "$O/$f" ] && [ ! -f "$DIR/$f" ]; then cp -p "$O/$f" "$DIR/$f" || die "не удалось перенести $f"; fi
        done
        if [ -d "$O/asn" ] && [ ! -d "$DIR/asn" ]; then cp -a "$O/asn" "$DIR/asn" || die 'не удалось скопировать AS'; fi
        if [ -f "$O/fvpn.conf" ] && [ ! -f "$DIR/razvilka.conf" ]; then cp -p "$O/fvpn.conf" "$DIR/razvilka.conf" || die 'не удалось перенести настройки'; fi
    fi
    for f in /opt/etc/init.d/S03foreign-vpn /opt/etc/init.d/S81foreign-vpn-web /opt/etc/ndm/netfilter.d/50-foreign-vpn.sh \
             /opt/etc/cron.1min/foreign-vpn /opt/etc/cron.hourly/foreign-vpn /opt/etc/cron.daily/foreign-vpn /opt/etc/cron.hourly/foreign-vpn-lists; do
        save_original "$f"
        rm -f "$f" || die "не удалось отключить $f"
    done
    ipset destroy fvpn_direct 2>/dev/null
    return 0
}
finish_legacy_migration() {
    [ "$LEGACY_MIGRATION" = 1 ] || return 0
    if [ -d /opt/foreign-vpn ]; then
        legacy_backup=$(mktemp -d /opt/root/foreign-vpn-old.XXXXXXXX) || return 1
        mv /opt/foreign-vpn "$legacy_backup/" || return 1
        c_ok "foreign-vpn перенесён; старая установка в $legacy_backup"
    fi
    if [ -f /opt/var/log/foreign-vpn.log ]; then
        cat /opt/var/log/foreign-vpn.log >> /opt/var/log/razvilka.log && rm -f /opt/var/log/foreign-vpn.log || return 1
    fi
    return 0
}

# ---------- перенос с Bird4Static / web4static ----------

migrate_bird() {
    [ -d /opt/Bird4Static ] || return 0
    mkdir -p "$DIR/lists" || die 'не удалось создать каталог списков Bird4Static'
    for p in "isp direct" "vpn vpn"; do
        from=/opt/Bird4Static/lists/user-${p% *}.list; to=$DIR/lists/${p#* }.list
        if [ -f "$from" ] && ! grep -qvE '^[[:space:]]*(#|$)' "$to" 2>/dev/null; then
            awk '!/^[[:space:]]*antifilter\.(download|network)[[:space:]]*$/' "$from" > "$to" || die "не удалось перенести список Bird4Static $from"
            c_ok "список Bird $(basename "$from") перенесён в lists/$(basename "$to")"
        fi
    done
    [ $KEEP_BIRD = 1 ] && { c_info "Bird4Static оставлен (--keep-bird)"; return 0; }
    c_info "удаляю Bird4Static (его работу берут на себя ручные списки razvilka)"
    bk=$(mktemp -d /opt/root/bird4static-backup.XXXXXXXX) || die 'не удалось создать каталог копии Bird4Static'
    cp -a /opt/Bird4Static "$bk/" || die 'не удалось сохранить Bird4Static'
    for f in /opt/etc/bird.conf /opt/etc/bird4-*.list /opt/etc/bird4-*.orig /opt/etc/init.d/S02bird-table /opt/etc/cron.hourly/add-bird4_routes.sh; do
        [ ! -f "$f" ] || cp -p "$f" "$bk/" || die "не удалось сохранить $f"
    done
    # Пакеты BIRD/PHP, общий lighttpd и настройки других сайтов могут использоваться независимо.
    if [ -x /opt/etc/init.d/S70bird ] && grep -qiE 'bird4static|bird4-' /opt/etc/bird.conf 2>/dev/null; then
        save_original /opt/etc/init.d/S70bird
        BIRD_SERVICE=1
        /opt/etc/init.d/S70bird stop || die 'не удалось остановить Bird4Static'
        chmod -x /opt/etc/init.d/S70bird || die 'не удалось отключить автозапуск Bird4Static'
    fi
    if [ -x /opt/etc/init.d/S02bird-table ]; then
        BIRD_TABLE=1
        /opt/etc/init.d/S02bird-table stop || die 'не удалось остановить таблицу Bird4Static'
    fi
    for f in /opt/etc/init.d/S02bird-table /opt/etc/cron.hourly/add-bird4_routes.sh; do
        save_original "$f"
        rm -f "$f" || die 'не удалось отключить Bird4Static'
    done
    BIRD_BACKUP=$bk
}

finish_bird_migration() {
    [ -n "$BIRD_BACKUP" ] || return 0
    rm -rf /opt/Bird4Static || { c_warn "не удалось удалить Bird4Static (копия — $BIRD_BACKUP)"; return 1; }
    c_ok "Bird4Static удалён (бэкап — $BIRD_BACKUP)"
    if opkg list-installed 2>/dev/null | grep -q '^web4static '; then
        opkg remove web4static || { c_warn 'не удалось удалить web4static'; return 1; }
    fi
    return 0
}

# ---------- установка ----------

# Файлы старой установки копируем до остановки. Готовые файлы публикуем переименованием.
install_files() {
    install_file razvilka.sh "$DIR/razvilka.sh" 755
    install_file www/index.sh "$DIR/www/index.sh" 755
    install_file www/favicon.svg "$DIR/www/favicon.svg" 644
    install_file www/status.sh "$DIR/www/status.sh" 755
    install_file lib/journal.awk "$DIR/journal.awk" 644
    install_file www/journal.css "$DIR/www/journal.css" 644
    install_file www/log.sh "$DIR/www/log.sh" 755
    install_file www/backup.sh "$DIR/www/backup.sh" 755
    install_file lighttpd.conf "$DIR/lighttpd.conf.in" 644
    install_file init/S03razvilka /opt/etc/init.d/S03razvilka 755
    install_file init/S81razvilka-web /opt/etc/init.d/S81razvilka-web 755
    install_file cron-1min /opt/etc/cron.1min/razvilka 755
    install_file cron-hourly /opt/etc/cron.hourly/razvilka 755
    install_file cron-daily /opt/etc/cron.daily/razvilka 755
}
save_original() {
    printf '%s\n' "$1" >> "$SRC/targets" || die 'не удалось записать список файлов установки'
    if [ -e "$1" ] || [ -L "$1" ]; then
        [ ! -d "$1" ] || die "ожидался файл, найден каталог: $1"
        mkdir -p "$SRC/original$(dirname "$1")" && cp -a "$1" "$SRC/original$1" || die "не удалось сохранить $1 до обновления"
    fi
}
install_file() {
    save_original "$2"
    [ -s "$SRC/$1" ] && chmod "$3" "$SRC/$1" || die "файл пакета отсутствует: $1"
    printf '%s|%s\n' "$1" "$2" >> "$SRC/package" || die 'не удалось записать список файлов пакета'
}
run_router() { LOCK_HELD=1 "$DIR/razvilka.sh" "$@"; }
run_web() { LOCK_HELD=1 /opt/etc/init.d/S81razvilka-web "$@" 8>&-; }

lock_setup() {
    mkdir -p "$DIR" || die 'не удалось создать каталог Razvilka'
    exec 8>>"$DIR/.lockf" || die 'не удалось открыть файл блокировки'
    flock -n 8 || die 'другая операция ещё выполняется, повторите позже'
}
rollback_install() {
    c_warn 'установка прервана; возвращаю прежние файлы и состояние'
    failed=0
    [ ! -x /opt/etc/init.d/S81razvilka-web ] || run_web stop >/dev/null 2>&1
    if [ -x "$DIR/razvilka.sh" ] && [ "$NEW_RUNTIME" = 1 ]; then
        for cmd in stop device-clear-rules ai-off 'ipv6-block off' alias-off; do run_router $cmd >/dev/null 2>&1 || failed=1; done
    fi
    while IFS= read -r dst; do
        old_file=$SRC/original$dst
        if [ -e "$old_file" ] || [ -L "$old_file" ]; then
            mv -f "$old_file" "$dst" || failed=1
        else
            rm -f "$dst" || failed=1
        fi
    done < "$SRC/targets"
    if [ "$LEGACY_MIGRATION" = 1 ]; then
        if [ "$LEGACY_ENABLED" = 1 ]; then /opt/foreign-vpn/fvpn.sh start >/dev/null 2>&1 || failed=1; fi
        [ ! -x /opt/etc/init.d/S81foreign-vpn-web ] || /opt/etc/init.d/S81foreign-vpn-web start 8>&- || failed=1
        if [ "$LEGACY_SHARED_WEB" = 1 ] && [ -x /opt/etc/init.d/S80lighttpd ]; then /opt/etc/init.d/S80lighttpd restart 8>&- || failed=1; fi
    fi
    if [ "$BIRD_TABLE" = 1 ]; then /opt/etc/init.d/S02bird-table start 8>&- || failed=1; fi
    if [ "${BIRD_SERVICE:-0}" = 1 ]; then /opt/etc/init.d/S70bird start 8>&- || failed=1; fi
    if [ -x "$DIR/razvilka.sh" ]; then
        if [ "$WAS_ENABLED" = 1 ]; then run_router start >/dev/null 2>&1 || failed=1
        elif grep -q '^    device-apply)' "$DIR/razvilka.sh"; then
            run_router device-apply >/dev/null 2>&1 && run_router ai-apply >/dev/null 2>&1 || failed=1
            if [ -f "$DIR/ipv6_block" ]; then run_router ipv6-block on >/dev/null 2>&1 || failed=1; fi
        fi
    fi
    [ ! -x /opt/etc/init.d/S81razvilka-web ] || run_web start >/dev/null 2>&1 || failed=1
    [ "$failed" = 0 ]
}

do_install() {
    [ "$(id -u)" = 0 ] || die "запускать от root"
    [ -x /opt/bin/opkg ] || die "нет Entware (/opt/bin/opkg)"
    echo "Razvilka $VERSION — установка"
    DEFAULT_IPV6=0; [ -f "$DIR/razvilka.conf" ] || DEFAULT_IPV6=1
    WAS_ENABLED=1
    if [ ! -f "$DIR/razvilka.conf" ] && [ -f /opt/foreign-vpn/fvpn.conf ]; then
        WAS_ENABLED=0; [ -f /opt/foreign-vpn/enabled ] && WAS_ENABLED=1
        [ -z "$VPN_IF" ] && VPN_IF=$(sed -n 's/^VPN_IF="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /opt/foreign-vpn/fvpn.conf | tail -1)
        [ -z "$ISP_IF" ] && ISP_IF=$(sed -n 's/^ISP_IF="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /opt/foreign-vpn/fvpn.conf | tail -1)
    elif [ -f "$DIR/razvilka.conf" ]; then
        WAS_ENABLED=0; [ -f "$DIR/enabled" ] && WAS_ENABLED=1
    fi

    detect_vpn; detect_isp
    [ -z "$VPN2_IF" ] && VPN2_IF=$(sed -n 's/^VPN2_IF="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$DIR/razvilka.conf" 2>/dev/null | tail -1)
    [ -z "$VPN2_SERVERS" ] && VPN2_SERVERS=$(sed -n 's/^VPN2_SERVERS_EXTRA="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$DIR/razvilka.conf" 2>/dev/null | tail -1)
    [ -z "$VPN2_PROCESS" ] && VPN2_PROCESS=$(sed -n 's/^VPN2_PROCESS="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$DIR/razvilka.conf" 2>/dev/null | tail -1)
    [ "$VPN2_IF" = none ] && VPN2_IF=
    ask "Дополнительный VPN-интерфейс (пусто — не использовать)" "$VPN2_IF"; VPN2_IF=$REPLY
    ask "VPN-интерфейс" "${VPN_IF:-opkgtun0}"; VPN_IF=$REPLY
    ask "Интерфейс провайдера" "${ISP_IF:-eth3}"; ISP_IF=$REPLY
    [ -n "$VPN_IF" ] && [ -d "/sys/class/net/$VPN_IF" ] || die "нет интерфейса VPN '$VPN_IF' — сначала поднимите VPN (или укажите --vpn-if)"
    [ -n "$ISP_IF" ] && [ -d "/sys/class/net/$ISP_IF" ] || die "нет интерфейса провайдера '$ISP_IF' (укажите --isp-if)"
    if [ -n "$VPN2_IF" ]; then
        [ "$VPN2_IF" != "$VPN_IF" ] || die 'дополнительный VPN должен отличаться от основного'
        [ -d "/sys/class/net/$VPN2_IF" ] || die "нет дополнительного VPN-интерфейса '$VPN2_IF'"
    fi
    if iface_ok "$VPN_IF"; then c_ok "VPN $VPN_IF отвечает"; else c_warn "VPN $VPN_IF сейчас не отвечает — поставлю, сторож включит, когда оживёт"; fi
    gateway=$(iface_gw "$ISP_IF")
    case "$gateway" in
        0.0.0.0) c_ok "провайдер: $ISP_IF (маршрут без шлюза)" ;;
        '') c_warn "нет маршрута по умолчанию на $ISP_IF" ;;
        *) c_ok "провайдер: $ISP_IF (шлюз $gateway)" ;;
    esac

    temp_routes_on
    c_info "пакеты Entware: $PKGS"
    missing=; core=; for p in $PKGS $OPT_PKGS; do opkg list-installed 2>/dev/null | grep -q "^$p " || missing="$missing $p"; done
    for p in $PKGS; do opkg list-installed 2>/dev/null | grep -q "^$p " || core="$core $p"; done
    # не хватает только необязательных, а туннель лежит — репозиторий наверняка душится, не ждём
    [ -z "$core" ] && [ -n "$missing" ] && ! iface_ok "$VPN_IF" && { c_warn "туннель лежит — необязательные пакеты ($missing) поставлю в другой раз"; missing=; }
    if [ -z "$missing" ]; then
        c_info "все пакеты уже стоят — репозиторий не трогаю"
    else
        # с таймаутом: при упавшем туннеле провайдер может душить репозиторий, и opkg висит вечно
        with_timeout() { t=$1; shift; "$@" & pid=$!; ( sleep "$t"; pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null ) & w=$!; wait $pid; rc=$?; kill $w 2>/dev/null; return $rc; }
        with_timeout 180 opkg update >/dev/null 2>&1 || c_warn "opkg update не завершился (провайдер режет репозиторий?) — пробую дальше"
        with_timeout 600 opkg install $missing > /opt/tmp/razvilka-opkg.log 2>&1 || true
    fi
    for p in $PKGS; do opkg list-installed | grep -q "^$p " || die "не встал пакет $p (см. /opt/tmp/razvilka-opkg.log)"; done
    for p in $OPT_PKGS; do opkg list-installed | grep -q "^$p " || c_warn "не встал необязательный пакет $p — поставлю при следующем запуске"; done
    if { [ "$DEFAULT_IPV6" = 1 ] || [ -f "$DIR/ipv6_block" ]; } && ! have ip6tables; then
        opkg install ip6tables >/dev/null 2>&1 && have ip6tables || die 'для включённой IPv6-блокировки требуется ip6tables'
    fi
    c_ok "пакеты на месте"
    temp_routes_off

    detect_lan_ip
    unpack

    lock_setup
    if [ -f "$DIR/razvilka.conf" ]; then
        WAS_ENABLED=0; [ ! -f "$DIR/enabled" ] || WAS_ENABLED=1
        DEFAULT_IPV6=0
    fi
    install_files
    for f in razvilka.conf lighttpd.conf enabled .service-stopped ai_protect ipv6_block failmode contact.txt web.users csrf.token lists/direct.list lists/vpn.list stub/index.html; do
        save_original "$DIR/$f"
    done
    save_original /opt/etc/crontab
    if [ ! -e /opt/bin/razvilka ] && [ ! -L /opt/bin/razvilka ]; then save_original /opt/bin/razvilka; fi
    save_original /opt/etc/ndm/netfilter.d/50-razvilka.sh
    LEGACY_MIGRATION=0; LEGACY_ENABLED=0; LEGACY_SHARED_WEB=0
    BIRD_BACKUP=; BIRD_TABLE=0; BIRD_SERVICE=0
    NEW_RUNTIME=0
    INSTALL_TRANSACTION=1

    # остановить старое, если есть (правила снимутся, списки и настройки останутся).
    # До переноса Bird: старая версия при stop включала обратно antifilter.
    if [ -x "$DIR/razvilka.sh" ]; then
        if ! run_router stop >/dev/null 2>&1 && grep -q '^stop_main()' "$DIR/razvilka.sh"; then
            die 'не удалось остановить прежнюю Razvilka'
        fi
        # Версии до 2026.11.24 возвращают из stop rc=1 даже при успешной остановке
        # (log() без return 0), поэтому проверяем факт, а не код возврата:
        # у выключенной схемы нет файла enabled. Если он остался — stop не сработал.
        if [ -f "$DIR/enabled" ]; then
            die 'не удалось остановить прежнюю Razvilka; повторите установку после завершения активной операции'
        fi
    fi
    [ ! -x /opt/etc/init.d/S81razvilka-web ] || run_web stop >/dev/null 2>&1 || die 'не удалось остановить веб-сервер'
    migrate_old_name
    migrate_bird

    mkdir -p "$DIR/www" "$DIR/stub" "$DIR/lists" /opt/var/log /opt/var/run /opt/etc/ndm/netfilter.d \
             /opt/etc/cron.1min /opt/etc/cron.hourly /opt/etc/cron.daily || die 'не удалось создать каталоги установки'
    while IFS='|' read -r source dest; do
        # При переносе внутри /opt mv не требует места для второй копии.
        mv -f "$SRC/$source" "$dest" || die "не удалось установить $dest"
    done < "$SRC/package"
    NEW_RUNTIME=1
    rm -f /opt/etc/ndm/netfilter.d/50-razvilka.sh || die 'не удалось убрать старый хук'
    # короткая команда: razvilka status. Чужой файл с тем же именем не трогаем
    if { [ -e /opt/bin/razvilka ] || [ -L /opt/bin/razvilka ]; } && [ "$(readlink /opt/bin/razvilka 2>/dev/null)" != "$DIR/razvilka.sh" ]; then
        c_warn "/opt/bin/razvilka уже занят другой программой — команду не ставлю, используйте $DIR/razvilka.sh"
    else
        ln -sf "$DIR/razvilka.sh" /opt/bin/razvilka || die 'не удалось установить команду razvilka'
    fi

    # настройки: прежние значения сохраняются, параметры командной строки важнее
    old() {
        [ -f "$DIR/razvilka.conf" ] || return 0
        awk -v k="$1=" 'index($0,k)==1 {
            v=substr($0,length(k)+1); q=substr(v,1,1)
            if ((q=="\"" || q=="\047") && substr(v,length(v))==q) v=substr(v,2,length(v)-2)
        } END {print v}' "$DIR/razvilka.conf"
    }
    OLD_HOSTNAME=$(old HOSTNAME_LAN); OLD_ALIAS_IP=$(old ALIAS_IP); OLD_LAN_IP=$(old LAN_IP)
    [ -z "$WEB_PORT" ] && WEB_PORT=$(old WEB_PORT); [ -z "$WEB_PORT" ] && WEB_PORT=98
    [ -z "$STUB_PORT" ] && STUB_PORT=$(old STUB_PORT); [ -z "$STUB_PORT" ] && STUB_PORT=8098
    [ -z "$VPN_SERVERS" ] && VPN_SERVERS=$(old VPN_SERVERS_EXTRA)
    [ -z "$VPN_RESTART" ] && VPN_RESTART=$(old VPN_RESTART)
    [ -z "$VPN_PROCESS" ] && VPN_PROCESS=$(old VPN_PROCESS)
    detect_restart
    LAN_IF=$(old LAN_IF); [ -n "$LAN_IF" ] || LAN_IF=br+
    CAPTIVE_STUB=$(old CAPTIVE_STUB); [ -z "$CAPTIVE_STUB" ] && CAPTIVE_STUB=0
    if [ -z "$HOSTNAME_LAN" ]; then
        if grep -q '^HOSTNAME_LAN=' "$DIR/razvilka.conf" 2>/dev/null; then
            HOSTNAME_LAN=${OLD_HOSTNAME:-none}
        else HOSTNAME_LAN=razvilka.lan; fi
    fi
    [ -z "$ALIAS_IP" ] && ALIAS_IP=$(old ALIAS_IP)
    if [ -n "$OLD_LAN_IP" ] && [ "$OLD_LAN_IP" != "$LAN_IP" ] && [ "$ALIAS_IP" = "${OLD_LAN_IP%.*}.254" ]; then
        ALIAS_IP=
    elif [ -n "$ALIAS_IP" ] && [ "${ALIAS_IP%.*}" != "${LAN_IP%.*}" ]; then
        c_warn "прежний alias $ALIAS_IP вне новой подсети — выбираю адрес заново"
        ALIAS_IP=
    fi
    if [ "$HOSTNAME_LAN" = none ]; then HOSTNAME_LAN=; ALIAS_IP=
    elif [ -z "$ALIAS_IP" ]; then
        # .254 той же сети, если он свободен и не попадает в диапазон DHCP
        cand=${LAN_IP%.*}.254
        in_pool=$(ndmc -c "show ip dhcp pool" 2>/dev/null | awk -v c="${cand##*.}" '/begin:/{split($2,a,".");b=a[4]} /end:/{split($2,a,".");if(c>=b && c<=a[4])print 1}')
        if [ -z "$in_pool" ] && ! ping -c1 -W1 "$cand" >/dev/null 2>&1; then ALIAS_IP=$cand
        else c_warn "адрес $cand занят или в диапазоне DHCP — имя $HOSTNAME_LAN не настраиваю (задайте --alias-ip)"; HOSTNAME_LAN=; fi
    fi
    cat > "$SRC/new.conf" <<EOF || die 'не удалось записать настройки'
# Razvilka $VERSION — настройки (пишет инсталлятор; можно править руками, потом razvilka.sh stop && razvilka.sh start)
VPN_IF="$VPN_IF"
VPN2_IF="$VPN2_IF"
VPN2_SERVERS_EXTRA="$(echo $VPN2_SERVERS)"
VPN2_PROCESS="$VPN2_PROCESS"
ISP_IF="$ISP_IF"
LAN_IF="$LAN_IF"
LAN_IP="$LAN_IP"
WEB_PORT="$WEB_PORT"
STUB_PORT="$STUB_PORT"
VPN_SERVERS_EXTRA="$(echo $VPN_SERVERS)"
VPN_RESTART="$VPN_RESTART"
VPN_PROCESS="$VPN_PROCESS"
# 1 = заглушка при kill switch. ОСТОРОЖНО: iPhone/Mac при ней отключают через Wi‑Fi весь трафик
CAPTIVE_STUB="$CAPTIVE_STUB"
HOSTNAME_LAN="$HOSTNAME_LAN"
ALIAS_IP="$ALIAS_IP"
EOF
    mv -f "$SRC/new.conf" "$DIR/razvilka.conf" || die 'не удалось установить настройки'
    alias_edit='/^#ALIAS_BEGIN/,/^#ALIAS_END/d'
    [ -z "$ALIAS_IP" ] || alias_edit="s/@ALIAS_IP@/$ALIAS_IP/"
    sed -e "s/@WEB_PORT@/$WEB_PORT/g" -e "s/@STUB_PORT@/$STUB_PORT/g" -e "s/@LAN_IP@/$LAN_IP/g" -e "$alias_edit" \
        "$DIR/lighttpd.conf.in" > "$SRC/web.conf" || die 'не удалось записать конфигурацию веб-сервера'
    mv -f "$SRC/web.conf" "$DIR/lighttpd.conf" || die 'не удалось установить конфигурацию веб-сервера'
    if [ -n "$FAILMODE" ]; then echo "$FAILMODE" > "$DIR/failmode" || die 'не удалось сохранить режим'; fi
    [ -f "$DIR/failmode" ] || echo direct > "$DIR/failmode" || die 'не удалось сохранить режим'
    if [ "$DEFAULT_IPV6" = 1 ]; then touch "$DIR/ipv6_block" || die 'не удалось включить настройку IPv6'; fi
    if [ -n "$CONTACT" ]; then printf '%s\n' "$CONTACT" > "$DIR/contact.txt" || die 'не удалось сохранить контакт'
    elif [ ! -s "$DIR/contact.txt" ] && [ -n "$TTY" ]; then
        ask "Контакт на заглушке (кому писать, если VPN упал)" ""
        [ -z "$REPLY" ] || printf '%s\n' "$REPLY" > "$DIR/contact.txt" || die 'не удалось сохранить контакт'
    fi
    for l in direct vpn; do
        [ -f "$DIR/lists/$l.list" ] || printf '# по одной записи на строку: домен, IP или подсеть\n' > "$DIR/lists/$l.list" || die 'не удалось создать список'
    done

    # пароль веб-морды
    if [ -n "$WEB_PASS" ]; then :
    elif [ -s "$DIR/web.users" ]; then c_info "пароль веб-морды прежний"
    elif [ -n "$TTY" ]; then
        printf 'Пароль веб-морды (логин admin): ' > /dev/tty; stty -echo < /dev/tty 2>/dev/null
        read -r WEB_PASS < /dev/tty; stty echo < /dev/tty 2>/dev/null; echo > /dev/tty
    fi
    if [ -z "$WEB_PASS" ] && [ ! -s "$DIR/web.users" ]; then
        WEB_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14); GENERATED=1
    fi
    if [ -n "$WEB_PASS" ]; then
        (umask 077; printf 'admin:%s\n' "$WEB_PASS" > "$SRC/web.users") && mv "$SRC/web.users" "$DIR/web.users" || die 'не удалось записать пароль панели'
    fi
    [ -s "$DIR/web.users" ] && chmod 600 "$DIR/web.users" || die 'не удалось записать пароль панели'
    if [ ! -s "$DIR/csrf.token" ]; then
        (umask 077; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "$DIR/csrf.token")
    fi
    [ "$(wc -c < "$DIR/csrf.token")" -ge 32 ] && chmod 600 "$DIR/csrf.token" || die 'не удалось записать CSRF-токен'

    # cron: нужна строка для cron.1min (в стандартном crontab Entware она есть)
    grep -q 'cron.1min' /opt/etc/crontab 2>/dev/null || echo '*/1 * * * * root /opt/bin/run-parts /opt/etc/cron.1min' >> /opt/etc/crontab || die 'не удалось обновить crontab'
    if [ -x /opt/etc/init.d/S10cron ]; then
        /opt/etc/init.d/S10cron restart 8>&- >/dev/null 2>&1 || /opt/etc/init.d/S10cron start 8>&- >/dev/null 2>&1 || die 'не удалось запустить cron'
    fi

    if [ "$WAS_ENABLED" = 1 ]; then touch "$DIR/enabled"; else rm -f "$DIR/enabled"; fi || die 'не удалось сохранить состояние схемы'
    run_router stub || die 'не удалось создать страницу заглушки'
    [ -s "$DIR/ru.cidr" ] || { c_info "качаю список российских сетей"; run_router update >/dev/null 2>&1 || die 'не удалось загрузить список российских сетей'; }
    if [ "$WAS_ENABLED" = 1 ]; then
        run_router start || die 'не удалось запустить маршрутизацию'
    else
        run_router device-apply && run_router ai-apply || die 'не удалось применить политики'
        if [ -f "$DIR/ipv6_block" ]; then run_router ipv6-block on || die 'не удалось применить IPv6-блокировку'; fi
    fi
    /opt/sbin/lighttpd -tt -f "$DIR/lighttpd.conf" > /opt/tmp/razvilka-lighttpd.log 2>&1 \
        || die "конфиг веб-сервера с ошибкой: $(head -3 /opt/tmp/razvilka-lighttpd.log | tr '\n' ' ')"
    run_web start >/dev/null 2>&1 || die 'не удалось запустить веб-сервер'

    echo
    "$DIR/razvilka.sh" status-kv | grep -E '^(tunnel|rule|failmode|ru|direct_n|vpn_n|servers)=' | sed 's/^/  /'
    sleep 1
    if run_web status >/dev/null 2>&1 && netstat -ltn 2>/dev/null | grep -q ":$WEB_PORT "; then c_ok "веб-морда: http://$LAN_IP:$WEB_PORT  (логин admin); статус без пароля: http://$LAN_IP:$WEB_PORT/status"
    else die "веб-морда не поднялась — см. /opt/var/log/razvilka-web.log"; fi
    NDM_SAVE=0
    if [ -n "$OLD_HOSTNAME" ] && { [ "$OLD_HOSTNAME" != "$HOSTNAME_LAN" ] || [ "$OLD_ALIAS_IP" != "$ALIAS_IP" ]; }; then
        for h in $OLD_HOSTNAME ${OLD_HOSTNAME%.*}.local; do ndmc -c "no ip host $h $OLD_ALIAS_IP" >/dev/null 2>&1; done
        NDM_SAVE=1
    fi
    if [ -n "$OLD_ALIAS_IP" ] && [ "$OLD_ALIAS_IP" != "$ALIAS_IP" ]; then
        ip addr del "$OLD_ALIAS_IP/32" dev br0 2>/dev/null
    fi
    # Именные записи сохраняем после успешной проверки новой версии.
    if [ -n "$HOSTNAME_LAN" ] && [ -n "$ALIAS_IP" ]; then
        for h in "$HOSTNAME_LAN" "${HOSTNAME_LAN%.*}.local"; do
            ndmc -c "ip host $h $ALIAS_IP" >/dev/null 2>&1 || c_warn "не удалось добавить DNS-запись $h"
        done
        NDM_SAVE=1
    fi
    if [ "$NDM_SAVE" = 1 ]; then ndmc -c "system configuration save" >/dev/null 2>&1 || c_warn 'не удалось сохранить DNS в конфигурации Keenetic'; fi

    [ "${GENERATED:-0}" = 1 ] && c_warn "сгенерирован пароль веб-морды: $WEB_PASS  (сменить: повторить установку с --web-pass)"
    [ -n "$HOSTNAME_LAN" ] && c_ok "по имени: http://$HOSTNAME_LAN — статус, http://$HOSTNAME_LAN/admin — панель"
    INSTALL_TRANSACTION=0
    finish_legacy_migration || die 'Razvilka установлена; не удалось архивировать foreign-vpn'
    finish_bird_migration || die 'Razvilka установлена; миграция Bird4Static завершилась частично'
    c_ok "готово. Журнал: /opt/var/log/razvilka.log"
}

do_uninstall() {
    if [ -d "$DIR" ] && have flock; then lock_setup; fi
    if [ ! -d "$DIR" ]; then c_info 'Razvilka уже удалена'; return 0; fi
    SAVED_FLAGS=
    for flag in enabled ai_protect ipv6_block; do
        [ ! -f "$DIR/$flag" ] || SAVED_FLAGS="$SAVED_FLAGS $flag"
    done
    RESTORE_UNINSTALL_PREFS=1
    CLEANUP_FAILED=0
    if [ -x "$DIR/razvilka.sh" ]; then
        if ! run_router stop >/dev/null 2>&1 && grep -q '^stop_main()' "$DIR/razvilka.sh"; then CLEANUP_FAILED=1; fi
        # rc старых версий ненадёжен (см. do_install) — проверяем факт остановки
        [ -f "$DIR/enabled" ] && CLEANUP_FAILED=1
        if grep -q '^    device-clear-rules)' "$DIR/razvilka.sh"; then
            run_router device-clear-rules >/dev/null 2>&1 || CLEANUP_FAILED=1
        fi
        if grep -q '^    ai-off)' "$DIR/razvilka.sh"; then
            run_router ai-off >/dev/null 2>&1 || CLEANUP_FAILED=1
        fi
        if grep -q '^    ipv6-block)' "$DIR/razvilka.sh"; then
            run_router ipv6-block off >/dev/null 2>&1 || CLEANUP_FAILED=1
        fi
    fi
    [ "$CLEANUP_FAILED" = 0 ] || die 'не удалось снять правила Razvilka; файлы оставлены, повторите удаление после завершения активной операции'
    if have ip && ip rule show | grep -E '^300(16|17|20|22):.*lookup (1019|1020|1022|103[0-6])' >/dev/null; then
        die 'в ядре остались правила Razvilka; файлы не удалены, устраните причину и повторите'
    fi
    if have ip6tables && ip6tables -C FORWARD -i 'br+' -j RAZVILKA_IP6 2>/dev/null; then
        die 'в ядре осталась IPv6-блокировка Razvilka; файлы не удалены, устраните причину и повторите'
    fi
    if [ -f "$DIR/razvilka.conf" ]; then
        hn=$(sed -n 's/^HOSTNAME_LAN="\(.*\)"$/\1/p' "$DIR/razvilka.conf"); ai=$(sed -n 's/^ALIAS_IP="\(.*\)"$/\1/p' "$DIR/razvilka.conf")
        if [ -n "$hn" ] && [ -n "$ai" ]; then
            for h in $hn ${hn%.*}.local; do ndmc -c "no ip host $h $ai" >/dev/null 2>&1; done
            ndmc -c "system configuration save" >/dev/null 2>&1
        fi
        [ -x "$DIR/razvilka.sh" ] && run_router alias-off
    fi
    [ ! -x /opt/etc/init.d/S81razvilka-web ] || run_web stop >/dev/null 2>&1 || die 'не удалось остановить веб-сервер'
    rm -f /opt/etc/init.d/S03razvilka /opt/etc/init.d/S81razvilka-web /opt/etc/ndm/netfilter.d/50-razvilka.sh \
          /opt/etc/cron.1min/razvilka /opt/etc/cron.hourly/razvilka /opt/etc/cron.daily/razvilka || die 'не удалось убрать автозапуск'
    [ "$(readlink /opt/bin/razvilka 2>/dev/null)" = "$DIR/razvilka.sh" ] && rm -f /opt/bin/razvilka
    if [ $PURGE = 1 ]; then
        rm -rf "$DIR" || die 'не удалось удалить файлы'
        RESTORE_UNINSTALL_PREFS=0
        c_ok "удалено полностью"
    else
        find "$DIR" -mindepth 1 -maxdepth 1 ! -name lists ! -name backups ! -name .lockf ! -name contact.txt ! -name web.users ! -name csrf.token ! -name devices.conf ! -name failmode ! -name kill-allow.presets ! -name razvilka.conf -exec rm -rf {} + || die 'не удалось удалить файлы программы'
        c_ok "удалено; списки и настройки оставлены в $DIR (полностью: uninstall --purge)"
    fi
    c_info "пакеты Entware (ip-full, iptables, lighttpd, ...) не удалялись"
}

# исходники пакета (base64 tar.gz) — подставляет build.sh
payload() { cat <<'__RAZVILKA_PAYLOAD__'
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
FwCEBAA=
__RAZVILKA_PAYLOAD__
}

case "$ACTION" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" status || echo "не установлено" ;;
    *) die "действие: install | uninstall | status" ;;
esac
exit 0
