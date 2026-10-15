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
VERSION="@VERSION@"
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
    # короткая команда: razvilka status. Чужой файл с тем же именем не трогаем
    if [ -e /opt/bin/razvilka ] && [ "$(readlink /opt/bin/razvilka 2>/dev/null)" != "$DIR/razvilka.sh" ]; then
        c_warn "/opt/bin/razvilka уже занят другой программой — команду не ставлю, используйте $DIR/razvilka.sh"
    else
        ln -sf "$DIR/razvilka.sh" /opt/bin/razvilka
    fi

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
          /opt/etc/cron.1min/razvilka /opt/etc/cron.hourly/razvilka /opt/etc/cron.daily/razvilka
    [ "$(readlink /opt/bin/razvilka 2>/dev/null)" = "$DIR/razvilka.sh" ] && rm -f /opt/bin/razvilka
    if [ $PURGE = 1 ]; then rm -rf "$DIR"; c_ok "удалено полностью"
    else
        find "$DIR" -mindepth 1 -maxdepth 1 ! -name lists ! -name contact.txt ! -name web.users ! -name failmode ! -name kill-allow.presets ! -name razvilka.conf -exec rm -rf {} +
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
