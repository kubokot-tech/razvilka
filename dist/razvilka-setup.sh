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
#   --contact TEXT      контакт на заглушке           --failmode kill|direct  (kill)
#   --keep-bird         не удалять Bird4Static/web4static (по умолчанию удаляются: списки переносятся)
#   --yes               не задавать вопросов
#
# Файл самодостаточный: исходники пакета лежат внутри (в конце, base64 tar.gz).

set -u
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root

DIR=/opt/razvilka
VERSION="2026.10.13-1719"
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
    opkg update >/dev/null 2>&1 || c_warn "opkg update с ошибками — пробую дальше"
    opkg install $PKGS > /opt/tmp/razvilka-opkg.log 2>&1 || true
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
    [ -f "$DIR/failmode" ] || echo kill > "$DIR/failmode"
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
