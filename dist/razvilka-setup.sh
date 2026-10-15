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
#   --vpn-if IF         интерфейс VPN-туннеля (opkgtun0, nwg0, ...)
#   --isp-if IF         интерфейс провайдера (eth3, ppp0, ...)
#   --vpn-server IP     адрес VPN-сервера, если не определяется сам (можно несколько раз)
#   --vpn-process NAME  имя процесса VPN-клиента — по его соединениям определяется адрес сервера
#   --vpn-restart CMD   команда перезапуска VPN для кнопки в веб-морде
#   --web-pass PASS     пароль веб-морды (логин admin); без него — спросит или оставит прежний
#   --web-port N        порт веб-морды (98)          --stub-port N   порт заглушки (8098)
#   --contact TEXT      контакт на заглушке           --failmode kill|direct  (direct; kill временно отключён)
#   --keep-bird         не удалять Bird4Static/web4static (по умолчанию удаляются: списки переносятся)
#   --yes               не задавать вопросов
#
# Файл самодостаточный: исходники пакета лежат внутри (в конце, base64 tar.gz).

set -u
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root

DIR=/opt/razvilka
VERSION="2026.10.15-2109"
PKGS="ip-full iptables ipset curl bind-dig cron lighttpd lighttpd-mod-cgi lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-rewrite lighttpd-mod-setenv"
OPT_PKGS="conntrack"     # необязательные: без них работает, но хуже (conntrack — сброс соединений при переключении)
REPO_HOSTS="bin.entware.net"

c_ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[1;36m•\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()    { printf '\033[1;31m✗ %s\033[0m\n' "$*"; exit 1; }

ACTION=${1:-install}; [ $# -gt 0 ] && shift
VPN_IF= ; ISP_IF= ; VPN_SERVERS= ; VPN_RESTART= ; VPN_PROCESS= ; WEB_PASS= ; WEB_PORT= ; STUB_PORT=
CONTACT= ; FAILMODE= ; KEEP_BIRD=0 ; YES=0 ; PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --vpn-if) VPN_IF=$2; shift ;;
        --isp-if) ISP_IF=$2; shift ;;
        --vpn-server) VPN_SERVERS="$VPN_SERVERS $2"; shift ;;
        --vpn-restart) VPN_RESTART=$2; shift ;;
        --vpn-process) VPN_PROCESS=$2; shift ;;
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

default_route_ifaces() { awk 'NR>1 && $2=="00000000" {print $1}' /proc/net/route; }
iface_gw() {  # шлюз интерфейса из /proc/net/route (hex little-endian -> a.b.c.d)
    awk -v i="$1" 'NR>1 && $1==i && $2=="00000000" {g=$3; printf "%d.%d.%d.%d\n", "0x" substr(g,7,2), "0x" substr(g,5,2), "0x" substr(g,3,2), "0x" substr(g,1,2); exit}' /proc/net/route
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
            if have ip; then ip route replace "$ip/32" dev "$VPN_IF" 2>/dev/null && TMP_ROUTES="$TMP_ROUTES ip:$ip"
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
trap 'temp_routes_off' EXIT INT TERM

# ---------- распаковка исходников из этого файла ----------

unpack() {
    SRC=/opt/tmp/razvilka-src.$$
    rm -rf "$SRC"; mkdir -p "$SRC"
    payload | base64 -d | tar xzf - -C "$SRC" || die "не удалось распаковать пакет"
}

# ---------- переезд со старого имени (foreign-vpn -> Razvilka) ----------

migrate_old_name() {
    O=/opt/foreign-vpn
    [ -d "$O" ] || [ -f /opt/etc/lighttpd/conf.d/85-fvpn.conf ] || return 0
    c_info "переношу прежнюю установку foreign-vpn в Razvilka"
    [ -x "$O/fvpn.sh" ] && "$O/fvpn.sh" stop >/dev/null 2>&1
    [ -x /opt/etc/init.d/S81foreign-vpn-web ] && /opt/etc/init.d/S81foreign-vpn-web stop >/dev/null 2>&1
    # самая первая версия подключалась к общему lighttpd
    if [ -f /opt/etc/lighttpd/conf.d/85-fvpn.conf ]; then
        rm -f /opt/etc/lighttpd/conf.d/85-fvpn.conf
        [ -x /opt/etc/init.d/S80lighttpd ] && /opt/etc/init.d/S80lighttpd restart >/dev/null 2>&1
    fi
    if [ -d "$O" ]; then
        mkdir -p "$DIR/lists"
        for f in lists/direct.list lists/vpn.list contact.txt web.users failmode ru.cidr asn-names; do
            [ -f "$O/$f" ] && [ ! -f "$DIR/$f" ] && cp -p "$O/$f" "$DIR/$f"
        done
        [ -d "$O/asn" ] && [ ! -d "$DIR/asn" ] && cp -a "$O/asn" "$DIR/asn"
        [ -f "$O/fvpn.conf" ] && [ ! -f "$DIR/razvilka.conf" ] && cp -p "$O/fvpn.conf" "$DIR/razvilka.conf"
        [ -f "$O/enabled" ] || rm -f "$DIR/enabled"
        mv "$O" "/opt/root/foreign-vpn-old-$(date +%Y%m%d%H%M)"
    fi
    [ -f /opt/var/log/foreign-vpn.log ] && cat /opt/var/log/foreign-vpn.log >> /opt/var/log/razvilka.log && rm -f /opt/var/log/foreign-vpn.log
    rm -f /opt/etc/init.d/S03foreign-vpn /opt/etc/init.d/S81foreign-vpn-web /opt/etc/ndm/netfilter.d/50-foreign-vpn.sh \
          /opt/etc/cron.1min/foreign-vpn /opt/etc/cron.hourly/foreign-vpn /opt/etc/cron.daily/foreign-vpn \
          /opt/etc/cron.hourly/foreign-vpn-lists /opt/var/log/foreign-vpn-web.log
    ipset destroy fvpn_direct 2>/dev/null
    c_ok "foreign-vpn перенесён: списки, контакт, пароль и режим сохранены (старая папка — /opt/root/foreign-vpn-old-*)"
}

# ---------- перенос с Bird4Static / web4static ----------

migrate_bird() {
    [ -d /opt/Bird4Static ] || [ -x /opt/etc/init.d/S70bird ] || return 0
    mkdir -p "$DIR/lists"
    for p in "isp direct" "vpn vpn"; do
        from=/opt/Bird4Static/lists/user-${p% *}.list; to=$DIR/lists/${p#* }.list
        if [ -f "$from" ] && ! grep -qvE '^[[:space:]]*(#|$)' "$to" 2>/dev/null; then
            grep -vE '^[[:space:]]*antifilter\.(download|network)[[:space:]]*$' "$from" > "$to"
            c_ok "список Bird $(basename "$from") перенесён в lists/$(basename "$to")"
        fi
    done
    [ $KEEP_BIRD = 1 ] && { c_info "Bird4Static оставлен (--keep-bird)"; return 0; }
    c_info "удаляю Bird4Static (его работу берут на себя ручные списки razvilka)"
    # busybox tar в Entware умеет только распаковывать — бэкап простым копированием
    bk=/opt/root/bird4static-backup-$(date +%Y%m%d%H%M); mkdir -p "$bk"
    cp -a /opt/Bird4Static /opt/etc/bird*.conf /opt/etc/bird4-*.list "$bk/" 2>/dev/null
    [ -x /opt/etc/init.d/S70bird ] && /opt/etc/init.d/S70bird stop >/dev/null 2>&1
    [ -x /opt/etc/init.d/S02bird-table ] && /opt/etc/init.d/S02bird-table stop >/dev/null 2>&1
    if have ip; then
        for pr in 30020 30021; do while ip rule show | grep -q "^$pr:"; do ip rule del priority $pr; done; done
        ip route flush table 1020 2>/dev/null; ip route flush table 1021 2>/dev/null
    fi
    rm -f /opt/etc/init.d/S70bird /opt/etc/init.d/S02bird-table /opt/etc/cron.hourly/add-bird4_routes.sh
    rm -rf /opt/Bird4Static /opt/etc/bird.conf /opt/etc/bird.conf-opkg /opt/etc/bird4-*.list /opt/etc/bird4-*.orig
    opkg remove bird2c bird2 iprange >/dev/null 2>&1
    c_ok "Bird4Static удалён (бэкап — $bk)"

    if opkg list-installed 2>/dev/null | grep -q '^web4static '; then
        c_info "удаляю web4static (веб-морда Bird) и PHP"
        opkg remove web4static >/dev/null 2>&1
        # пакеты php8 зависят друг от друга — удаляем по кругу, пока не уйдут все
        for i in 1 2 3 4; do
            p=$(opkg list-installed | awk '/^php8/{print $1}'); [ -z "$p" ] && break
            opkg remove $p >/dev/null 2>&1
        done
        rm -f /opt/etc/opkg/feedly.conf /opt/etc/lighttpd/conf.d/80-w4s.conf /opt/etc/lighttpd/conf.d/81-w4s-local.conf
        rm -rf /opt/share/www/w4s
        # общий lighttpd больше никому не нужен — останавливаем, чтобы не мешал
        # (в conf.d остаются только загрузчики модулей — ищем, есть ли там чей-то сайт)
        if [ -x /opt/etc/init.d/S80lighttpd ] && ! grep -qsE 'server\.port|SERVER\["socket"\]|document-root' /opt/etc/lighttpd/conf.d/*.conf; then
            /opt/etc/init.d/S80lighttpd stop >/dev/null 2>&1; chmod -x /opt/etc/init.d/S80lighttpd
        fi
        c_ok "web4static удалён"
    fi
}

# ---------- установка ----------

do_install() {
    [ "$(id -u)" = 0 ] || die "запускать от root"
    [ -x /opt/bin/opkg ] || die "нет Entware (/opt/bin/opkg)"
    echo "Razvilka $VERSION — установка"

    detect_vpn; detect_isp
    ask "VPN-интерфейс" "${VPN_IF:-opkgtun0}"; VPN_IF=$REPLY
    ask "Интерфейс провайдера" "${ISP_IF:-eth3}"; ISP_IF=$REPLY
    [ -n "$VPN_IF" ] && [ -d "/sys/class/net/$VPN_IF" ] || die "нет интерфейса VPN '$VPN_IF' — сначала поднимите VPN (или укажите --vpn-if)"
    [ -n "$ISP_IF" ] && [ -d "/sys/class/net/$ISP_IF" ] || die "нет интерфейса провайдера '$ISP_IF' (укажите --isp-if)"
    if iface_ok "$VPN_IF"; then c_ok "VPN $VPN_IF отвечает"; else c_warn "VPN $VPN_IF сейчас не отвечает — поставлю, сторож включит, когда оживёт"; fi
    c_ok "провайдер: $ISP_IF (шлюз $(iface_gw "$ISP_IF"))"

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
        with_timeout() { t=$1; shift; "$@" & pid=$!; ( sleep "$t"; kill $pid 2>/dev/null; pkill -P $pid 2>/dev/null; killall wget 2>/dev/null ) & w=$!; wait $pid; rc=$?; kill $w 2>/dev/null; return $rc; }
        with_timeout 180 opkg update >/dev/null 2>&1 || c_warn "opkg update не завершился (провайдер режет репозиторий?) — пробую дальше"
        with_timeout 600 opkg install $missing > /opt/tmp/razvilka-opkg.log 2>&1 || true
    fi
    for p in $PKGS; do opkg list-installed | grep -q "^$p " || die "не встал пакет $p (см. /opt/tmp/razvilka-opkg.log)"; done
    for p in $OPT_PKGS; do opkg list-installed | grep -q "^$p " || c_warn "не встал необязательный пакет $p — поставлю при следующем запуске"; done
    c_ok "пакеты на месте"
    temp_routes_off

    detect_lan_ip; detect_restart
    unpack

    # остановить старое, если есть (правила снимутся, списки и настройки останутся).
    # До переноса Bird: старая версия при stop включала обратно antifilter.
    [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" stop >/dev/null 2>&1
    [ -x /opt/etc/init.d/S81razvilka-web ] && /opt/etc/init.d/S81razvilka-web stop >/dev/null 2>&1
    migrate_old_name
    migrate_bird

    mkdir -p "$DIR/www" "$DIR/stub" "$DIR/lists" /opt/var/log /opt/var/run /opt/etc/ndm/netfilter.d \
             /opt/etc/cron.1min /opt/etc/cron.hourly /opt/etc/cron.daily
    install_file() { cp "$SRC/$1" "$2" && chmod "$3" "$2"; }
    install_file razvilka.sh "$DIR/razvilka.sh" 755
    install_file www/index.sh "$DIR/www/index.sh" 755
    install_file www/favicon.svg "$DIR/www/favicon.svg" 644
    install_file init/S03razvilka /opt/etc/init.d/S03razvilka 755
    install_file init/S81razvilka-web /opt/etc/init.d/S81razvilka-web 755
    # хук netfilter.d больше не нужен (был частью kill switch, который вешал роутер) — убираем у старых установок
    rm -f /opt/etc/ndm/netfilter.d/50-razvilka.sh
    install_file cron-1min /opt/etc/cron.1min/razvilka 755
    install_file cron-hourly /opt/etc/cron.hourly/razvilka 755
    install_file cron-daily /opt/etc/cron.daily/razvilka 755
    ln -sf "$DIR/razvilka.sh" /opt/bin/razvilka   # короткая команда: razvilka status

    # настройки: прежние значения сохраняются, параметры командной строки важнее
    old() { [ -f "$DIR/razvilka.conf" ] && sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$DIR/razvilka.conf" | tail -1; }
    [ -z "$WEB_PORT" ] && WEB_PORT=$(old WEB_PORT); [ -z "$WEB_PORT" ] && WEB_PORT=98
    [ -z "$STUB_PORT" ] && STUB_PORT=$(old STUB_PORT); [ -z "$STUB_PORT" ] && STUB_PORT=8098
    [ -z "$VPN_SERVERS" ] && VPN_SERVERS=$(old VPN_SERVERS_EXTRA)
    [ -z "$VPN_RESTART" ] && VPN_RESTART=$(old VPN_RESTART)
    [ -z "$VPN_PROCESS" ] && VPN_PROCESS=$(old VPN_PROCESS)
    CAPTIVE_STUB=$(old CAPTIVE_STUB); [ -z "$CAPTIVE_STUB" ] && CAPTIVE_STUB=0
    cat > "$DIR/razvilka.conf" <<EOF
# Razvilka $VERSION — настройки (пишет инсталлятор; можно править руками, потом razvilka.sh stop && razvilka.sh start)
VPN_IF="$VPN_IF"
ISP_IF="$ISP_IF"
LAN_IF='br+'
LAN_IP="$LAN_IP"
WEB_PORT="$WEB_PORT"
STUB_PORT="$STUB_PORT"
VPN_SERVERS_EXTRA="$(echo $VPN_SERVERS)"
VPN_RESTART="$VPN_RESTART"
VPN_PROCESS="$VPN_PROCESS"
# 1 = заглушка при kill switch. ОСТОРОЖНО: iPhone/Mac при ней отключают через Wi‑Fi весь трафик
CAPTIVE_STUB="$CAPTIVE_STUB"
EOF
    sed -e "s/@WEB_PORT@/$WEB_PORT/g" -e "s/@STUB_PORT@/$STUB_PORT/g" "$SRC/lighttpd.conf" > "$DIR/lighttpd.conf"

    [ -n "$FAILMODE" ] && echo "$FAILMODE" > "$DIR/failmode"
    [ -f "$DIR/failmode" ] || echo direct > "$DIR/failmode"
    if [ -n "$CONTACT" ]; then printf '%s\n' "$CONTACT" > "$DIR/contact.txt"
    elif [ ! -s "$DIR/contact.txt" ] && [ -n "$TTY" ]; then
        ask "Контакт на заглушке (кому писать, если VPN упал)" ""; [ -n "$REPLY" ] && printf '%s\n' "$REPLY" > "$DIR/contact.txt"
    fi
    for l in direct vpn; do
        [ -f "$DIR/lists/$l.list" ] || printf '# по одной записи на строку: домен, IP или подсеть\n' > "$DIR/lists/$l.list"
    done

    # пароль веб-морды
    if [ -n "$WEB_PASS" ]; then :
    elif [ -s "$DIR/web.users" ]; then c_info "пароль веб-морды прежний"
    elif [ -n "$TTY" ]; then
        printf 'Пароль веб-морды (логин admin): ' > /dev/tty; stty -echo < /dev/tty 2>/dev/null
        read -r WEB_PASS < /dev/tty; stty echo < /dev/tty 2>/dev/null; echo > /dev/tty
    fi
    if [ -z "$WEB_PASS" ] && [ ! -s "$DIR/web.users" ]; then
        WEB_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14); GENERATED=1
    fi
    [ -n "$WEB_PASS" ] && (umask 077; printf 'admin:%s\n' "$WEB_PASS" > "$DIR/web.users")
    chmod 600 "$DIR/web.users"

    # cron: нужна строка для cron.1min (в стандартном crontab Entware она есть)
    grep -q 'cron.1min' /opt/etc/crontab 2>/dev/null || echo '*/1 * * * * root /opt/bin/run-parts /opt/etc/cron.1min' >> /opt/etc/crontab
    [ -x /opt/etc/init.d/S10cron ] && { /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || /opt/etc/init.d/S10cron start >/dev/null 2>&1; }

    touch "$DIR/enabled"
    "$DIR/razvilka.sh" stub
    [ -s "$DIR/ru.cidr" ] || { c_info "качаю список российских сетей"; "$DIR/razvilka.sh" update >/dev/null 2>&1; }
    "$DIR/razvilka.sh" start
    /opt/sbin/lighttpd -tt -f "$DIR/lighttpd.conf" > /opt/tmp/razvilka-lighttpd.log 2>&1 \
        || c_warn "конфиг веб-сервера с ошибкой: $(head -3 /opt/tmp/razvilka-lighttpd.log | tr '\n' ' ')"
    /opt/etc/init.d/S81razvilka-web restart >/dev/null 2>&1
    rm -rf "$SRC"

    echo
    "$DIR/razvilka.sh" status-kv | grep -E '^(tunnel|rule|failmode|ru|direct_n|vpn_n|servers)=' | sed 's/^/  /'
    sleep 1
    if netstat -ltn 2>/dev/null | grep -q ":$WEB_PORT "; then c_ok "веб-морда: http://$LAN_IP:$WEB_PORT  (логин admin)"
    else c_warn "веб-морда не поднялась — см. /opt/var/log/razvilka-web.log"; fi
    [ "${GENERATED:-0}" = 1 ] && c_warn "сгенерирован пароль веб-морды: $WEB_PASS  (сменить: повторить установку с --web-pass)"
    c_ok "заглушка: http://$LAN_IP:$STUB_PORT"
    c_ok "готово. Журнал: /opt/var/log/razvilka.log"
}

do_uninstall() {
    [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" stop >/dev/null 2>&1
    [ -x /opt/etc/init.d/S81razvilka-web ] && /opt/etc/init.d/S81razvilka-web stop >/dev/null 2>&1
    rm -f /opt/etc/init.d/S03razvilka /opt/etc/init.d/S81razvilka-web /opt/etc/ndm/netfilter.d/50-razvilka.sh \
          /opt/etc/cron.1min/razvilka /opt/etc/cron.hourly/razvilka /opt/etc/cron.daily/razvilka /opt/bin/razvilka
    if [ $PURGE = 1 ]; then rm -rf "$DIR"; c_ok "удалено полностью"
    else
        find "$DIR" -mindepth 1 -maxdepth 1 ! -name lists ! -name contact.txt ! -name web.users ! -name failmode ! -name razvilka.conf -exec rm -rf {} +
        c_ok "удалено; списки и настройки оставлены в $DIR (полностью: uninstall --purge)"
    fi
    c_info "пакеты Entware (ip-full, iptables, lighttpd, ...) не удалялись"
}

# исходники пакета (base64 tar.gz) — подставляет build.sh
payload() { cat <<'__RAZVILKA_PAYLOAD__'
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
__RAZVILKA_PAYLOAD__
}

case "$ACTION" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" status || echo "не установлено" ;;
    *) die "действие: install | uninstall | status" ;;
esac
exit 0
