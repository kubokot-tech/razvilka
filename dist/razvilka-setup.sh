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
VERSION="2026.10.13-1418"
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
