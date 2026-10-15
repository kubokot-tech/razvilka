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
#   --failmode direct|soft|kill  поведение при падении туннеля (direct)
#   --keep-bird         не удалять Bird4Static/web4static (по умолчанию удаляются: списки переносятся)
#   --yes               не задавать вопросов
#
# Файл самодостаточный: исходники пакета лежат внутри (в конце, base64 tar.gz).

set -u
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root

DIR=/opt/razvilka
VERSION="2026.10.15-2140"
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
    install_file www/status.sh "$DIR/www/status.sh" 755
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
    if netstat -ltn 2>/dev/null | grep -q ":$WEB_PORT "; then c_ok "веб-морда: http://$LAN_IP:$WEB_PORT  (логин admin); статус без пароля: http://$LAN_IP:$WEB_PORT/status"
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
        find "$DIR" -mindepth 1 -maxdepth 1 ! -name lists ! -name contact.txt ! -name web.users ! -name failmode ! -name kill-allow.presets ! -name razvilka.conf -exec rm -rf {} +
        c_ok "удалено; списки и настройки оставлены в $DIR (полностью: uninstall --purge)"
    fi
    c_info "пакеты Entware (ip-full, iptables, lighttpd, ...) не удалялись"
}

# исходники пакета (base64 tar.gz) — подставляет build.sh
payload() { cat <<'__RAZVILKA_PAYLOAD__'
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
cL18pVsSJVHN0SqgWXbya4VIffZmQNIGMEwsD7pv0g1XE0hoULVuZ+3kHzimeBiW6FIBbuOjP7/+
1k19cfL/njwnGO6vTt8Pb/6a4jOHMTCfhI/+M1X2Q+kLDpMnfPQrMgF/pW4VJmhyLMCQJ4w8CmA4
9oM/7NB738rQ66EF8ljyV8QKiuzwD35ZIw+Pl3Zx3D095ri6/0l5BqCVnBbd5+pkQWy5S4xyGu3G
mtqlsg9NZOWtD5jvnv4Uxy5yM2TGeTP4Nm7On35y8gUdmZKoFvK4ZVZHtFXRG8zpqDw6eGFPG2UU
b/8YK/xbHuaKqGy5Zd+lQcahhv92V8LrHPzayi13c2VR2s2V3qiYj3Luj6rmqzn33ZAC/Bfpt2ci
XpsMJdr16Hgb7lSGWwmSFBjdD5Kls5ZuypHRA0RCOzEfihRuh8g1AvmaQRRMZDJ0BzHnHrSDcpQl
XCqwTFlgAbPA+w64F5G0aSTjiXweBSOaHu1IY3/JSAJfqtCCGh0Nj5PGzgY90QGVI03+SCGUfUAk
DQ+6fPNb96AoLgWDfnNr7ZunqTs/vHnz6g0zuJ+EaOfofqC/bG/wHb3jpHbS9P4MIshv0LEWddQa
d9cILx+PvOfaGFfCLMgORoU72yG0iUJDEtaW3Vo0B+xxFRs6ipJibElGve8tHz914hpTGRuXanM4
ssUY2RiW3oOriSilatfY2FxUuWoE/Eh+Rk+LcK+Uz2jziX8MtBg75hE9z74v1I76qkKATQhCQ6vM
3GFFP0Pcj3ZWDWdNYyte7XjzISuknJ9I7ylmleSh+GUt4byCjOAmY37gnc/NsNFWoGzbK3HKRnuI
mfK19IpcnONwqsITQq+Q2CluXCghiYKJmcmahRuLj6F9JHrLFOwWuR06E2WaQyraoK/UK6GnLB7j
d0wHuBj8r3XaKGOhjbwiFOqagu7is/qv1MOd78SlmAR8r90vLZwB66mxcoxloCsTosYlZK+9e86Y
ryzyGSSOHQyjrpjsbhHFX3OidUMcoPCeBE2ToAm00qZBpF0ENpfBOD40Bu3ktUnwUwiS4PGyNFd3
cVo6g1jp9fYZThk7duqRHVd18a886deUMTs96j0EIy9DEiYN8RQHpsQR0bogTmZ1OH4ReiJ6OjIS
p0BSTPGSjlpGRGLlpsVBS/mgjrV4rMENy5YuRUYvzZyY4eScSk3n74u5p3DS9r/tt2VV0lhq8if5
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
Hhixx9D6/zwWaVZPZZOnMF9T+6pkZ2BwWLmGzJL1S8A5QB2MVOtSKLrGgh2MugGokJWEmaqHCZXK
3PZu2HStZyannZVwjPHSoOOWpbyWeK5Z5nYhzChKEGgsDlAyOWC2fkA8VdyV7PP+AbKx67cOVKsO
EknIgSIN4uYB0IEDnH8HekIdGON+wE3RA2XWlWjO9/6In3xhb2+v8N2WUSwWlyoVQd9V/i56Zf6W
H+FWvGrZc6tVICtFt1QuF78nKt9ttfgzwTGCqjwMdkfjoT/u7yang2Tt9ox8ZDv097+TT77QHPZ7
ORdo8XdWBvRHtVyeMf4wOXD8S2W3uLRUgfEvwwT4nih+ZzUyPv+bj/+5VwqNTq8w2koV+oNxQbEW
/SMPXEGT9z92Zf/0+dY/cv23gLc+/K7KOHv9l6Lrv1os/mn9/yE+86x/FpP+tPr/V/zI9b/Vnwy/
MwJw9vr3Iuu/UnSX/rT+/xCfedY/6Ud/Wv7/S35Y/2MNFcb6Oyljtv7n4dJX+t9S0UX9r1Jyq39a
/3+IT7j+z4mT39hYaZHzJ+K2pAk1iklQKxQumadt1mory3Ii2bHU6JgQWtE+ydohYk5/TrZpcvPP
Jp0v40OdGk0c/U/lCQaC4MunggcE/X3r8p036kS/oC01+jHSvyajId/mW/QH7430L/gh3njrzauc
BUJEpV67frue3r/9lxtk24SrWs6ij4epaz+6ddNIgpe1HJnmDdJ5mLrx1utGKriSGe36w0K3vxkm
hovDVCoYNb8D4Llg1+/ifmcaaxla5SLb7OwQQgGC/dy7G/cv1u8a/lO1wkbu/gWKOkyVu0r+hIsy
aaa+mL+QSRfWN+659YV73kIB94VhTn3z2xKMs/CUlzvGNP3mtxXrysPdxOcCE37zNNWaDLUPyrie
dleVk9rYCGU+ZhxANF2bjaANNzb4OYZrDHvZ4CmBcWG5Wi4W8QTAFl2fp+tCqco3d/gmXhaqRTOe
erpF1vKijvEtdzNaXPn0FtSe9lU59VZyakwl0jvK7B2m30lOb6UcBRo5lMINSVt16Gz/EW/CHqb2
IAvlNtRTbkPQOezj0RLOD/DWwsXzrfz5HTQpx508yCuI/AL21zfgGyZ3uAlwmGJXBexlf7MP36nQ
oXF9w3RnMFAcow9yCDabhrwdexiNHRXlEYENiueQ4dKhYpMh7lNAViIn7EQZGEToE3KACFpUY11P
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
