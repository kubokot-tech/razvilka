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
VERSION="2026.10.15-2143"
PKGS="ip-full iptables ipset curl bind-dig cron lighttpd lighttpd-mod-cgi lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-rewrite lighttpd-mod-setenv"
OPT_PKGS="conntrack"     # необязательные: без них работает, но хуже (conntrack — сброс соединений при переключении)
REPO_HOSTS="bin.entware.net"

c_ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
c_info() { printf '\033[1;36m•\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()    { printf '\033[1;31m✗ %s\033[0m\n' "$*"; exit 1; }

ACTION=${1:-install}; [ $# -gt 0 ] && shift
VPN_IF= ; ISP_IF= ; VPN_SERVERS= ; VPN_RESTART= ; VPN_PROCESS= ; HOSTNAME_LAN= ; ALIAS_IP= ; WEB_PASS= ; WEB_PORT= ; STUB_PORT=
CONTACT= ; FAILMODE= ; KEEP_BIRD=0 ; YES=0 ; PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --vpn-if) VPN_IF=$2; shift ;;
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
    [ -z "$HOSTNAME_LAN" ] && HOSTNAME_LAN=$(old HOSTNAME_LAN); [ -z "$HOSTNAME_LAN" ] && HOSTNAME_LAN=razvilka.lan
    [ -z "$ALIAS_IP" ] && ALIAS_IP=$(old ALIAS_IP)
    if [ "$HOSTNAME_LAN" = none ]; then HOSTNAME_LAN=; ALIAS_IP=
    elif [ -z "$ALIAS_IP" ]; then
        # .254 той же сети, если он свободен и не попадает в диапазон DHCP
        cand=${LAN_IP%.*}.254
        in_pool=$(ndmc -c "show ip dhcp pool" 2>/dev/null | awk -v c="${cand##*.}" '/begin:/{split($2,a,".");b=a[4]} /end:/{split($2,a,".");if(c>=b && c<=a[4])print 1}')
        if [ -z "$in_pool" ] && ! ping -c1 -W1 "$cand" >/dev/null 2>&1; then ALIAS_IP=$cand
        else c_warn "адрес $cand занят или в диапазоне DHCP — имя $HOSTNAME_LAN не настраиваю (задайте --alias-ip)"; HOSTNAME_LAN=; fi
    fi
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
HOSTNAME_LAN="$HOSTNAME_LAN"
ALIAS_IP="$ALIAS_IP"
EOF
    sed -e "s/@WEB_PORT@/$WEB_PORT/g" -e "s/@STUB_PORT@/$STUB_PORT/g" "$SRC/lighttpd.conf" > "$DIR/lighttpd.conf"
    if [ -n "$ALIAS_IP" ]; then sed -i "s/@ALIAS_IP@/$ALIAS_IP/" "$DIR/lighttpd.conf"
    else sed -i '/^#ALIAS_BEGIN/,/^#ALIAS_END/d' "$DIR/lighttpd.conf"; fi
    # имя в DNS роутера (статическая запись Keenetic)
    if [ -n "$HOSTNAME_LAN" ] && [ -n "$ALIAS_IP" ]; then
        "$DIR/razvilka.sh" alias-on
        for h in $HOSTNAME_LAN ${HOSTNAME_LAN%.*}.local; do ndmc -c "ip host $h $ALIAS_IP" >/dev/null 2>&1; done
        ndmc -c "system configuration save" >/dev/null 2>&1
    fi

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
    [ -n "$HOSTNAME_LAN" ] && c_ok "по имени: http://$HOSTNAME_LAN — статус, http://$HOSTNAME_LAN/admin — панель"
    c_ok "готово. Журнал: /opt/var/log/razvilka.log"
}

do_uninstall() {
    [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" stop >/dev/null 2>&1
    if [ -f "$DIR/razvilka.conf" ]; then
        hn=$(sed -n 's/^HOSTNAME_LAN="\(.*\)"$/\1/p' "$DIR/razvilka.conf"); ai=$(sed -n 's/^ALIAS_IP="\(.*\)"$/\1/p' "$DIR/razvilka.conf")
        if [ -n "$hn" ] && [ -n "$ai" ]; then
            for h in $hn ${hn%.*}.local; do ndmc -c "no ip host $h $ai" >/dev/null 2>&1; done
            ndmc -c "system configuration save" >/dev/null 2>&1
        fi
        [ -x "$DIR/razvilka.sh" ] && "$DIR/razvilka.sh" alias-off
    fi
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
ScrZ4LGJkd+cVaeTEeapFSWfOzxEsIcSvUMVh0UlM3+D8Vfrfy1QSGHgtLlNLyp58l9Qa9L6X60F
rVoDBIygWW/5i/V/FyVl/cN29+qPCtpSYEXTGj5VSkod7ocdiP+8Ogca8T35Oq5IPd6/4vpHuPAP
6Vkv8ZzR9XNB2cHHg0658PTJhx9/QCti2h5Wh5Owas49b7DbKcDFcDdklzgiBcUSPiXt8OTAX/Gj
wx50r2ztTtFTLp28pK/H9t5ue1Q5CNeFxAF9KKj5CD+UeoskeVJ3aDOaoD+qM4V9HHUAt2++Z5wg
FUtStF0Xo71udyCCdXXNRW8McDIGSuzAnBnG5MI6jUEhE4pvjSAtyqIsyqIsyp2U/wFScnzsAKAB
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
