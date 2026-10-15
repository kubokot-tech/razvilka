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
VERSION="2026.10.15-2119"
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
        find "$DIR" -mindepth 1 -maxdepth 1 ! -name lists ! -name contact.txt ! -name web.users ! -name failmode ! -name kill-allow.presets ! -name razvilka.conf -exec rm -rf {} +
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
