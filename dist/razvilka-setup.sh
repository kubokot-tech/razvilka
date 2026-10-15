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
VERSION="2026.10.15-2101"
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
