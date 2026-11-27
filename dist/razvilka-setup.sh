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
VERSION="2026.11.27-1427"
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
    awk -v i="$1" 'NR>1 && $1==i && $2=="00000000" && $8=="00000000" {g=$3; printf "%d.%d.%d.%d\n", "0x" substr(g,7,2), "0x" substr(g,5,2), "0x" substr(g,3,2), "0x" substr(g,1,2); exit}' /proc/net/route
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
P2J7AIQEAA==
__RAZVILKA_PAYLOAD__
}

case "$ACTION" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" status || echo "не установлено" ;;
    *) die "действие: install | uninstall | status" ;;
esac
exit 0
