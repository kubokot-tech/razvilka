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
VERSION="2026.10.15-1929"
PKGS="ip-full iptables ipset curl bind-dig cron lighttpd lighttpd-mod-cgi lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-rewrite lighttpd-mod-setenv"
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
    for i in $(vpn_candidates); do iface_ok "$i" && { VPN_IF=$i; return 0; }; done
    VPN_IF=$(vpn_candidates | head -1)
}
detect_isp() {
    [ -n "$ISP_IF" ] && return 0
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
    missing=; for p in $PKGS; do opkg list-installed 2>/dev/null | grep -q "^$p " || missing="$missing $p"; done
    if [ -z "$missing" ]; then
        c_info "все пакеты уже стоят — репозиторий не трогаю"
    else
        # с таймаутом: при упавшем туннеле провайдер может душить репозиторий, и opkg висит вечно
        with_timeout() { t=$1; shift; "$@" & pid=$!; ( sleep "$t"; kill $pid 2>/dev/null; pkill -P $pid 2>/dev/null; killall wget 2>/dev/null ) & w=$!; wait $pid; rc=$?; kill $w 2>/dev/null; return $rc; }
        with_timeout 180 opkg update >/dev/null 2>&1 || c_warn "opkg update не завершился (провайдер режет репозиторий?) — пробую дальше"
        with_timeout 600 opkg install $missing > /opt/tmp/razvilka-opkg.log 2>&1 || true
    fi
    for p in $PKGS; do opkg list-installed | grep -q "^$p " || die "не встал пакет $p (см. /opt/tmp/razvilka-opkg.log)"; done
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
    install_file netfilter.sh /opt/etc/ndm/netfilter.d/50-razvilka.sh 755
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
PwhGwl1TaVm0xGiOaUUqmLdxr1kZ7uVlYrT1OX82YvPd57vPd5/vPt99/rf5/C+BjY/rAEIBAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
