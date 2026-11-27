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
VERSION="@VERSION@"
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
@PAYLOAD@

case "$ACTION" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" status || echo "не установлено" ;;
    *) die "действие: install | uninstall | status" ;;
esac
exit 0
