#!/bin/sh
# Razvilka — весь иностранный трафик через VPN, российский напрямую, с kill switch.
# Ставится инсталлятором (razvilka-setup.sh), настройки — /opt/razvilka/razvilka.conf.
#
# Порядок правил маршрутизации (первое совпадение выигрывает):
#   30016 -> table 1030–1038   индивидуальные политики: direct, primary/secondary VPN, fail-closed
#   30017 -> table 1019   AI-защита: VPN metric 10 + постоянный prohibit metric 100
#   30020 -> table 1020   ручные списки: lists/direct.list (напрямую), lists/vpn.list (через VPN);
#                         записи — домен, IP, подсеть или автономная система (AS13238)
#   30022 -> table 1022   сети РФ напрямую, VPN-сервер напрямую, локальное как есть, остальное -> VPN
#
# Когда VPN упал (файл failmode, переключается в веб-морде):
#   kill   — kill switch: зарубежное с устройств не пускаем напрямую. HTTP (порт 80)
#            заворачиваем на страницу-заглушку, остальное (HTTPS и т.п.) сразу сбрасываем.
#            Трафик самого роутера (DNS, переподключение VPN) идёт напрямую.
#   direct — отпускаем зарубежное напрямую.
#
#   razvilka.sh start | stop          включить / выключить основную схему (AI-защита независима)
#   razvilka.sh ai-on | ai-off        fail-closed защита Claude Code / ChatGPT
#   razvilka.sh update                перекачать список сетей РФ и перестроить
#   razvilka.sh lists                 перечитать ручные списки (домены -> IP, AS -> подсети), раз в час
#   razvilka.sh lists refresh         то же, но подсети AS скачать заново (не ждать суток)
#   razvilka.sh why IP                из какой записи ручного списка взялся адрес
#   razvilka.sh lookup IP             всё про адрес: маршрут, списки, РФ ли, чья AS (для веб-морды)
#   razvilka.sh watchdog              раз в минуту из cron
#   razvilka.sh mode direct|soft|kill
#   razvilka.sh killtest N | off      показать заглушку N минут при живом VPN (проверка)
#   razvilka.sh stub                  пересобрать страницу-заглушку (после смены контакта)
#   razvilka.sh netfilter             переприменить правила iptables (хук ndm/netfilter.d)
#   razvilka.sh vpn-restart           перезапустить VPN (команда VPN_RESTART из razvilka.conf)
#   razvilka.sh status | status-kv

export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root

DIR=/opt/razvilka

# --- настройки по умолчанию; переопределяются в razvilka.conf (пишет инсталлятор) ---
load_router_config() {
    VPN_IF=opkgtun0
    VPN2_IF=
    VPN2_SERVERS_EXTRA=
    VPN2_PROCESS=
    ISP_IF=eth3
    LAN_IF='br+'             # все бриджи: домашняя и гостевая сети
    LAN_IP=192.168.1.1
    STUB_PORT=8098
    WEB_PORT=98
    VPN_SERVERS_EXTRA=""     # адреса VPN-сервера вручную, если не определяются сами
    VPN_PROCESS=""           # имя процесса VPN-клиента: по его соединениям находится адрес сервера
    ALIAS_IP=""              # отдельный адрес для веб-морды на 80-м порту (http://razvilka.lan)
    HOSTNAME_LAN=""          # имя для него в DNS роутера
    CAPTIVE_STUB=0           # 1 = при kill switch подменять http на зарубежное страницей-заглушкой. ОСТОРОЖНО:
                             # iPhone/Mac принимают её за «вход в сеть» и перестают пускать через Wi‑Fi ВЕСЬ трафик
    VPN_RESTART=""           # команда перезапуска VPN для кнопки в веб-морде
    [ ! -f "$DIR/razvilka.conf" ] || . "$DIR/razvilka.conf"
}
load_router_config || exit 1

TABLE=1022
PRIO=30022
FORCE_TABLE=1020
FORCE_PRIO=30020
AI_TABLE=1019
AI_PRIO=30017
AI_ENABLED=$DIR/ai_protect
AI_RESOLVED=$DIR/ai.resolved
AI_FAILED=$DIR/ai.failed
AI_DNS_MAP=$DIR/ai.dns.map
AI_VOICE_RESOLVED=$DIR/ai.voice.resolved
AI_DNS_TTL=86400
AI_DNS_MAX_MISSES=3
AI_VOICE_URL='https://openai.com/chatgpt-voice.json'
DEVICES_FILE=$DIR/devices.conf
DEV_PRIO=30016
DEV_DIRECT_TABLE=1030
DEV_VPN_TABLE=1031
DEV_VPN2_TABLE=1033
DEV_ALL_TABLE=1034
DEV_ALL2_TABLE=1036
DEV_LIST_TABLE=1037
DEV_LIST2_TABLE=1038
DEV_LEGACY_TABLES="1032 1035"
DEV_TABLES="$DEV_DIRECT_TABLE $DEV_VPN_TABLE $DEV_VPN2_TABLE $DEV_ALL_TABLE $DEV_ALL2_TABLE $DEV_LIST_TABLE $DEV_LIST2_TABLE $DEV_LEGACY_TABLES"
SET=razvilka_direct          # ipset для правила заглушки (см. блок kill switch)
LISTS=$DIR/lists
DIRECT_LIST=$LISTS/direct.list
VPN_LIST=$LISTS/vpn.list
RU_LIST=$DIR/ru.cidr
ASN_DIR=$DIR/asn           # кэш подсетей автономных систем (AS13238.cidr)
ASN_TTL=86400              # обновлять раз в сутки
ASN_API="https://stat.ripe.net/data/announced-prefixes/data.json?resource="
ENABLED=$DIR/enabled
STATE=$DIR/state          # маршрут провайдера и VPN-серверы, с которыми строилась таблица
FORCE_STATE=$DIR/force_state
FAILS=$DIR/fails          # подряд неудачных проверок туннеля
MODE_FILE=$DIR/failmode   # kill | direct
KILL_FLAG=$DIR/kill_active
TEST_UNTIL=$DIR/killtest_until
CONTACT=$DIR/contact.txt
LOG=/opt/var/log/razvilka.log

SOURCES="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone
https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt"

# Не трогаем локальное и служебное: throw -> поиск продолжается в main.
PRIVATE="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"

# Публичные DNS: при упавшем VPN пускаем напрямую, иначе устройства с «зашитым»
# DNS (Android, Chromecast, ТВ) потеряют и российские сайты.
RESOLVERS="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220 94.140.14.14 94.140.15.15"

IPV4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
    # журнал не даём разрастись
    [ "$(wc -c < "$LOG")" -gt 200000 ] && tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    return 0
}

LOCK_FILE=$DIR/.lockf
LOCK_HELD=${LOCK_HELD:-0}
lock_release() {
    [ "$LOCK_HELD" = 1 ] || return 0
    flock -u 9 2>/dev/null
    exec 9>&-
    LOCK_HELD=0
}
lock_acquire() {
    [ "$LOCK_HELD" = 1 ] && return 0
    mkdir -p "$DIR" "$LISTS" "$(dirname "$LOG")"
    : >> "$LOCK_FILE" || { log 'не удалось открыть файл блокировки'; return 1; }
    exec 9>>"$LOCK_FILE"
    if ! flock -n 9; then
        exec 9>&-
        log 'другая операция ещё выполняется, повторите позже'
        return 2
    fi
    LOCK_HELD=1
    trap 'lock_release' EXIT
    trap 'exit 1' HUP INT TERM
}

# режим при падении туннеля: direct (всё напрямую) | soft (закрыто, кроме kill-allow) | kill (закрыто всё)
scheme_running() { [ -f "$ENABLED" ] && [ ! -f "$DIR/.service-stopped" ]; }
failmode() { m=$(cat "$MODE_FILE" 2>/dev/null); case "$m" in direct|soft) echo "$m" ;; *) echo kill ;; esac; }

# ---------- мягкий kill: что разрешено напрямую, когда туннель лежит ----------
ALLOW_LIST=$LISTS/kill-allow.list          # свои записи (домены, IP, подсети, AS)
ALLOW_PRESETS=$DIR/kill-allow.presets      # включённые наборы, по одному ключу на строку
ALLOW_DEFAULT="cloudflare akamai fastly jslibs gfonts captcha"

# наборы: ключ|название|записи
presets() {
    cat <<'P'
cloudflare|Cloudflare — CDN многих российских сайтов|AS13335
akamai|Akamai|AS20940 AS16625
fastly|Fastly|AS54113
jslibs|CDN библиотек (cdnjs, jsDelivr, unpkg)|cdnjs.cloudflare.com cdn.jsdelivr.net fastly.jsdelivr.net unpkg.com
gfonts|Шрифты и библиотеки Google|fonts.googleapis.com fonts.gstatic.com ajax.googleapis.com
captcha|Капча (reCAPTCHA, hCaptcha)|www.recaptcha.net recaptcha.net www.gstatic.com hcaptcha.com js.hcaptcha.com
analytics|Аналитика Google|www.google-analytics.com www.googletagmanager.com
P
}
presets_on() { [ -f "$ALLOW_PRESETS" ] && cat "$ALLOW_PRESETS" || echo $ALLOW_DEFAULT | tr ' ' '\n'; }

# записи всех включённых наборов + свои -> allow.resolved (резолвим заранее, пока туннель жив)
build_allow() {
    {
        for k in $(presets_on); do presets | awk -F'|' -v k="$k" '$1==k {print $3}' | tr ' ' '\n'; done
        [ -f "$ALLOW_LIST" ] && sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOW_LIST" | grep -v '^$'
    } > "$DIR/allow.src"
    list_map "$DIR/allow.src" | awk '{print $1}' | sort -u > "$DIR/allow.new"
    if [ -s "$DIR/allow.src" ] && [ ! -s "$DIR/allow.new" ]; then
        rm -f "$DIR/allow.new"
        return 1
    fi
    mv "$DIR/allow.new" "$DIR/allow.resolved"
}

isp_nexthop() {
    # PPPoE: "default dev ppp0 scope link". Пустой результат означает, что маршрута нет.
    ip route show table main default | awk -v iface="$ISP_IF" '
        $1 == "default" || $1 == "nexthop" {
            gw = dev = ""
            for (i=2; i<NF; i++) {
                if ($i == "via") gw = $(i+1)
                if ($i == "dev") dev = $(i+1)
            }
            if (dev == iface) {
                if (gw != "") printf "via %s ", gw
                print "dev " dev
                exit
            }
        }'
}

isp_route_state() (
    gw=
    case "$1" in "via "*) gw=${1#via }; gw=${gw%% *} ;; esac
    # После пересоздания ppp0 имя прежнее, а ядро удалило маршруты старого интерфейса.
    printf 'gw=%s wan_dev=%s wan_index=%s' "$gw" "${1##* }" "$(cat "/sys/class/net/$ISP_IF/ifindex" 2>/dev/null)"
)

isp_prefix_routes() {  # nexthop, таблица, файл префиксов
    awk -v hop="$1" -v t="$2" '{print "route replace " $1 " " hop " table " t}' "$3"
}

# dig, а не nslookup: busybox nslookup дописывает после IP имя из PTR-записи
resolve() { dig +short +time=3 +tries=1 "$1" A 2>/dev/null | grep -E "$IPV4" | grep -v '^127\.'; }
valid_public_ipv4() {
    awk -v ip="$1" 'BEGIN {
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
        split(ip,o,"."); for (i=1;i<=4;i++) if (o[i] < 0 || o[i] > 255) exit 1
        if (o[1] == 0 || o[1] == 10 || o[1] == 127 || o[1] >= 224) exit 1
        if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) exit 1
        if (o[1] == 169 && o[2] == 254) exit 1
        if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) exit 1
        if (o[1] == 192 && o[2] == 168) exit 1
        if (o[1] == 198 && (o[2] == 18 || o[2] == 19)) exit 1
    }'
}
valid_public_prefix() {
    p=$1; ipn=${p%/*}; bits=${p#*/}
    [ "$bits" -ge 0 ] 2>/dev/null && [ "$bits" -le 32 ] 2>/dev/null && valid_public_ipv4 "$ipn"
}

# Адреса VPN-сервера — должны идти напрямую, иначе петля. Источники:
# соединения процесса VPN-клиента (VPN_PROCESS), endpoints AmneziaWG/WireGuard, VPN_SERVERS_EXTRA.
# Последние найденные запоминаются: когда VPN лежит, соединения нет, а адрес всё равно нужен.
vpn_servers() {
    ifn=${1:-$VPN_IF}; extra=${2-$VPN_SERVERS_EXTRA}; proc=${3-$VPN_PROCESS}
    cache=$DIR/servers.last; [ "$ifn" = "$VPN_IF" ] || cache=$DIR/servers.$ifn.last
    live=$({
        [ -n "$proc" ] && netstat -tunp 2>/dev/null | awk -v p="/$proc" 'index($NF, p) == 1 || index($NF, p) > 0 {split($5, a, ":"); print a[1]}'
        for t in awg wg; do
            command -v $t >/dev/null 2>&1 && $t show "$ifn" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1
        done
    } | grep -E "$IPV4" | grep -vE '^(0\.|127\.|10\.|192\.168\.)' | sort -u)
    [ -n "$live" ] && echo "$live" > "$cache"
    { [ -n "$live" ] && echo "$live" || cat "$cache" 2>/dev/null
      for s in $extra; do echo "$s"; done
    } | grep -E "$IPV4" | sort -u
}

tunnel_ok() {
    ifn=${1:-$VPN_IF}
    [ -n "$ifn" ] && ip link show "$ifn" >/dev/null 2>&1 || return 1
    ping -I "$ifn" -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -I "$ifn" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1
}

download() {
    for u in $SOURCES; do
        # сначала через туннель: провайдер может душить зарубежные хостинги
        for via in "--interface $VPN_IF" ""; do
            if curl -sfL -m 60 $via "$u" -o "$DIR/ru.new" 2>/dev/null; then
                grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$DIR/ru.new" | sort -u > "$DIR/ru.clean"
                n=$(wc -l < "$DIR/ru.clean")
                if [ "$n" -gt 3000 ]; then
                    mv "$DIR/ru.clean" "$RU_LIST"; rm -f "$DIR/ru.new"
                    log "список РФ обновлён: $n сетей ($u)"
                    return 0
                fi
                log "источник $u вернул подозрительно мало ($n), пропускаю"
            fi
        done
    done
    rm -f "$DIR/ru.new" "$DIR/ru.clean"
    log "не удалось скачать список РФ, оставляю старый"
    return 1
}

build() {
    priority_available "$PRIO" "$TABLE" || return 1
    down=${1:-}
    wan_route=$(isp_nexthop)
    wan_state=$(isp_route_state "$wan_route")
    servers=$(vpn_servers)
    if [ "$down" != down ]; then
        [ -n "$wan_route" ] || { log "нет маршрута по умолчанию на $ISP_IF"; return 1; }
        ip link show "$VPN_IF" >/dev/null 2>&1 || { log "нет интерфейса $VPN_IF"; return 1; }
        [ -n "$servers" ] || { log "не нашёл адрес VPN-сервера, задайте VPN_SERVERS_EXTRA"; return 1; }
        [ -s "$RU_LIST" ] || download || return 1
    fi
    # Обновляем активную таблицу без flush. Запасной prohibit сохраняется даже при ошибке batch.
    {
        echo "route replace prohibit default metric 100 table $TABLE"
        [ "$down" != down ] || echo "route replace prohibit default table $TABLE"
        for p in $PRIVATE; do
            echo "route replace throw $p table $TABLE"
        done
        if [ -n "$wan_route" ]; then
            for s in $servers; do echo "route replace $s/32 $wan_route table $TABLE"; done
            [ ! -s "$RU_LIST" ] || isp_prefix_routes "$wan_route" "$TABLE" "$RU_LIST"
        fi
        [ "$down" = down ] || echo "route replace default dev $VPN_IF metric 10 table $TABLE"
    } > "$DIR/batch"
    reconcile_routes "$DIR/batch" "$TABLE" 'основная таблица: ошибка ip -batch' || return 1
    flush_cache
    echo "$wan_state servers=$(echo $servers)" > "$STATE"
    log "таблица $TABLE обновлена"
}

reconcile_routes() {
    table_routes "$2" > "$1.before" || return 1
    # Сверяем ключи (префикс, metric), чтобы снять старые исключения и временный prohibit.
    awk -v t="$2" '
        function key(p,m) { sub(/\/32$/, "", p); return p "|" m }
        FILENAME == ARGV[1] {
            prefix=($3 == "prohibit" || $3 == "throw" ? $4 : $3); metric=0
            for (i=4;i<NF;i++) if ($i=="metric") metric=$(i+1)
            want[key(prefix,metric)]=1; next
        }
        NF {
            prefix=($1 == "prohibit" || $1 == "throw" ? $2 : $1); metric=0
            for (i=2;i<NF;i++) if ($i=="metric") metric=$(i+1)
            if (!(key(prefix,metric) in want)) print "route del " prefix " metric " metric " table " t
        }' "$1" "$1.before" > "$1.remove"
    cat "$1.remove" >> "$1" || return 1
    batch_apply "$1" "$3"
}

# Новое ядро возвращает ENOENT для таблицы, которая ещё не создана. Другие ошибки
# (включая отсутствие прав) не должны выглядеть как корректная пустая таблица.
table_routes() (
    if rows=$(LC_ALL=C ip route show table "$1" 2>&1); then
        [ -z "$rows" ] || printf '%s\n' "$rows"
    else
        case "$rows" in
            *"FIB table does not exist"*) return 0 ;;
            *) printf '%s\n' "$rows" >&2; return 1 ;;
        esac
    fi
)
table_count() (
    rows=$(table_routes "$1") || return 1
    if [ -z "$rows" ]; then echo 0; else printf '%s\n' "$rows" | wc -l; fi
)
flush_table() (
    rows=$(table_routes "$1") || return 1
    [ -z "$rows" ] || ip route flush table "$1"
)

# у ядра Keenetic есть кэш маршрутов: после любой перестройки его надо сбрасывать,
# иначе старые решения живут ещё какое-то время
flush_cache() { ip route flush cache 2>/dev/null; }

# Return 0 for an exact rule, 1 if absent, 2 for an unrelated rule at this priority.
rule_status() (
    rules=$(ip rule show) || return 3
    printf '%s\n' "$rules" | awk -v pr="$1:" -v table="$2" -v sel="${3:-}" -v check="${4:-owned}" \
        -v dp="$DEV_PRIO:" -v dt=" $DEV_TABLES " -v gp="$GUARD_PRIO:" -v nets=" $GUARD_NETS " '
        BEGIN {
            src=(sel ~ /^from / ? sel : "from all" (sel == "" ? "" : " " sel))
            expected=pr " " src " lookup " table
        }
        $1 == pr {
            line=$0
            gsub(/[[:space:]]+/, " ", line)
            sub(/^ /, "", line); sub(/ $/, "", line)
            if (line == expected) found=1
            else if (pr == dp && NF == 5 && $2 == "from" && $3 ~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ && $4 == "lookup" && index(dt," " $5 " ")) next
            else if (pr == gp && NF == 7 && $2 == "from" && $3 == "all" && $4 == "to" && index(nets," " $5 " ") && $6 == "lookup" && $7 == "main") next
            else foreign=1
        }
        END { if (foreign && check != "exact") exit 2; exit !found }'
)
priority_available() {
    rule_status "$@" && return 0
    [ "$?" = 1 ] || { log "приоритет $1 занят чужим правилом"; return 1; }
}
rule_ensure() {
    rule_status "$@" && return 0
    [ "$?" = 1 ] || { log "приоритет $1 занят чужим правилом"; return 1; }
    ip rule add ${3:-} table "$2" priority "$1" || return 1
    rule_status "$@" || { log "не удалось подтвердить ip rule $1"; return 1; }
}
rule_remove() {
    while :; do
        rule_status "$1" "$2" "${3:-}" exact || { [ "$?" = 1 ]; return; }
        ip rule del ${3:-} table "$2" priority "$1" || return 1
    done
}
batch_apply() {
    f=$1; msg=$2; fallback=${3:-}
    if ip -batch "$f" 2> "$f.err"; then return 0; fi
    log "$msg: $(head -3 "$f.err" | tr '\n' ' ')"
    [ -n "$fallback" ] || return 1
    ip -batch "$fallback" 2> "$fallback.err" || { log "$msg (fallback): $(head -3 "$fallback.err" | tr '\n' ' ')"; return 1; }
}

# Страховка: всё, что адресовано в частные сети (домашняя сеть, ответы устройствам, сам роутер),
# идёт по обычной таблице main, мимо таблиц Razvilka. Даже если наша таблица окажется пустой или
# сломанной, домашняя сеть и доступ к роутеру не пострадают (15.10: без этого kill switch на
# недостроенной таблице отправлял ответы в домашнюю сеть провайдеру, и роутер «пропадал»).
GUARD_PRIO=30018
GUARD_NETS="10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4"
guard_on() {
    for p in $GUARD_NETS; do
        rule_ensure $GUARD_PRIO main "to $p" || return 1
    done
}
guard_off() {
    for p in $GUARD_NETS; do
        rule_remove $GUARD_PRIO main "to $p" || return 1
    done
}

# Сброс соединений домашней сети при смене маршрута: Keenetic уводит установленные соединения в аппаратное
# ускорение (FASTNAT), и они живут по старому маршруту, пока не закроются сами (15.10: после включения
# kill switch Gmail и ChatGPT ещё какое-то время ходили напрямую). Устройства тут же переоткроют их заново.
flush_flows() {
    command -v conntrack >/dev/null 2>&1 || return 0
    for n in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12; do conntrack -D -s $n >/dev/null 2>&1; done
    return 0
}

# shellcheck shell=sh
# ---------- блокировка внешнего IPv6 ----------

IPV6_BLOCK_FILE=$DIR/ipv6_block
IPV6_CHAIN=RAZVILKA_IP6

ipv6_rules() {
    for p in fe80::/10 fc00::/7 ff00::/8; do
        echo "-A $IPV6_CHAIN -d $p -j RETURN"
    done
    echo "-A $IPV6_CHAIN -p ipv6-icmp -j RETURN"
    echo "-A $IPV6_CHAIN -j DROP"
}

ipv6_block_on() {
    [ -f "$IPV6_BLOCK_FILE" ] || return 0
    command -v ip6tables >/dev/null 2>&1 || { log 'IPv6-блокировка: ip6tables не найден'; return 1; }
    active=$(ip6tables -S "$IPV6_CHAIN" 2>/dev/null | sed -n '/^-A /{s/ -p icmpv6 / -p ipv6-icmp /;p;}')
    if [ "$active" != "$(ipv6_rules)" ]; then
        if ip6tables -C FORWARD -i "$LAN_IF" -j "$IPV6_CHAIN" 2>/dev/null; then
            # COMMIT меняет цепочку целиком. Ошибка разбора оставляет прежние правила.
            { echo '*filter'; echo "-F $IPV6_CHAIN"; ipv6_rules; echo COMMIT; } |
                ip6tables-restore --noflush || { log 'не удалось обновить цепочку IPv6'; return 1; }
        else
            # Подключаем новую цепочку к FORWARD только после успешного заполнения.
            ip6tables -N "$IPV6_CHAIN" 2>/dev/null || ip6tables -S "$IPV6_CHAIN" >/dev/null || return 1
            ip6tables -F "$IPV6_CHAIN" || return 1
            ipv6_rules | while read -r rule; do ip6tables $rule || exit 1; done || return 1
        fi
    fi
    ip6tables -C FORWARD -i "$LAN_IF" -j "$IPV6_CHAIN" 2>/dev/null ||
        ip6tables -I FORWARD -i "$LAN_IF" -j "$IPV6_CHAIN"
}

ipv6_block_off() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    while ip6tables -C FORWARD -i "$LAN_IF" -j "$IPV6_CHAIN" 2>/dev/null; do
        ip6tables -D FORWARD -i "$LAN_IF" -j "$IPV6_CHAIN" || return 1
    done
    if ip6tables -S "$IPV6_CHAIN" >/dev/null 2>&1; then
        ip6tables -F "$IPV6_CHAIN" && ip6tables -X "$IPV6_CHAIN"
    fi
}
# shellcheck shell=sh
# ---------- fail-closed защита Claude Code / ChatGPT ----------

ai_is_on() { [ -f "$AI_ENABLED" ]; }
ai_domains() {
    cat <<'D'
api.openai.com
auth.openai.com
auth0.openai.com
chat.openai.com
chatgpt.com
www.chatgpt.com
ws.chatgpt.com
platform.openai.com
cdn.platform.openai.com
cdn.openaimerge.com
oaistatic.com
cdn.oaistatic.com
files.oaiusercontent.com
api.anthropic.com
claude.ai
www.claude.ai
claude.com
www.claude.com
platform.claude.com
sso.claude.com
mcp-proxy.anthropic.com
downloads.claude.ai
bridge.claudeusercontent.com
assets-proxy.anthropic.com
code.claude.com
D
}
ai_refresh() {
    ai_is_on || return 0
    now=$(date +%s)
    if [ ! -f "$AI_DNS_MAP" ]; then
        # Миграция со старого накопительного списка: даём адресам сутки на подтверждение.
        [ -f "$AI_RESOLVED" ] && awk -v now="$now" '{print "legacy|" $1 "|" now "|0"}' "$AI_RESOLVED" > "$AI_DNS_MAP" || : > "$AI_DNS_MAP"
    fi
    : > "$DIR/ai.failed.new"
    voice_ok=0
    for via in "--interface $VPN_IF" ""; do
        : > "$DIR/ai.voice.json"
        if curl -sf -m 20 $via "$AI_VOICE_URL" -o "$DIR/ai.voice.json" 2>/dev/null; then voice_ok=1; break; fi
    done
    if [ "$voice_ok" = 1 ] && [ -s "$DIR/ai.voice.json" ]; then
        grep -oE '"ipv4Prefix": ?"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+"' "$DIR/ai.voice.json" | grep -oE '[0-9.]+/[0-9]+' | while read -r p; do
            valid_public_prefix "$p" && echo "${p%/32}"
        done | sort -u > "$DIR/ai.voice.new"
        [ -s "$DIR/ai.voice.new" ] && mv "$DIR/ai.voice.new" "$AI_VOICE_RESOLVED"
    fi
    rm -f "$DIR/ai.voice.json" "$DIR/ai.voice.new"
    for d in $(ai_domains); do
        resolve "$d" | while read -r ipn; do valid_public_ipv4 "$ipn" && echo "$ipn"; done | sort -u > "$DIR/ai.current"
        if [ ! -s "$DIR/ai.current" ]; then
            echo "$d" >> "$DIR/ai.failed.new"
            continue
        fi
        awk -F'|' -v d="$d" -v now="$now" -v ttl="$AI_DNS_TTL" -v maxmiss="$AI_DNS_MAX_MISSES" -v current="$DIR/ai.current" '
            BEGIN { while ((getline ipn < current) > 0) seen[ipn]=1 }
            $1 == d {
                if ($2 in seen) { print d "|" $2 "|" now "|0"; seen[$2]=0; next }
                miss=$4+1
                if (miss < maxmiss || now-$3 < ttl) print $1 "|" $2 "|" $3 "|" miss
                next
            }
            { print }
            END { for (ipn in seen) if (seen[ipn]) print d "|" ipn "|" now "|0" }
        ' "$AI_DNS_MAP" > "$DIR/ai.dns.new"
        mv "$DIR/ai.dns.new" "$AI_DNS_MAP"
    done
    if [ ! -s "$DIR/ai.failed.new" ]; then
        awk -F'|' -v now="$now" -v ttl="$AI_DNS_TTL" '$1 != "legacy" || now-$3 < ttl' "$AI_DNS_MAP" > "$DIR/ai.dns.new"
        mv "$DIR/ai.dns.new" "$AI_DNS_MAP"
    fi
    {
        echo '160.79.104.0/23 153.61.224.0/22' | tr ' ' '\n'
        [ -f "$AI_VOICE_RESOLVED" ] && cat "$AI_VOICE_RESOLVED"
        awk -F'|' '{print $2}' "$AI_DNS_MAP"
    } | sed 's|/32$||' | sort -u > "$DIR/ai.resolved.new"
    mv "$DIR/ai.resolved.new" "$AI_RESOLVED"
    mv "$DIR/ai.failed.new" "$AI_FAILED"
    date +%s > "$DIR/ai.refreshed"
}
ai_ok() {
    ai_is_on || return 1
    ip rule show | grep -q "^$AI_PRIO:.*lookup $AI_TABLE" || return 1
    [ -s "$AI_RESOLVED" ] || return 1
    while read -r p; do
        p=${p%/32}
        ip route show table $AI_TABLE | awk -v p="$p" '$1 == "prohibit" && $2 == p {found=1} END {exit !found}' || return 1
    done < "$AI_RESOLVED"
}
ai_apply() {
    ai_is_on || return 0
    [ -s "$AI_RESOLVED" ] || ai_refresh
    [ -s "$AI_RESOLVED" ] || { log 'AI-защита: нет адресов для защиты'; return 1; }
    {
        # Запасной prohibit не зависит от VPN-интерфейса: при его удалении VPN-маршрут
        # исчезает из ядра, а запрет остаётся и не даёт провалиться в таблицу main.
        awk '{print "route replace prohibit " $1 " metric 100 table '"$AI_TABLE"'"}' "$AI_RESOLVED"
        if ip link show "$VPN_IF" >/dev/null 2>&1; then
            awk '{print "route replace " $1 " dev '"$VPN_IF"' metric 10 table '"$AI_TABLE"'"}' "$AI_RESOLVED"
        fi
    } > "$DIR/ai.batch"
    awk '{print "route replace prohibit " $1 " metric 100 table '"$AI_TABLE"'"}' "$AI_RESOLVED" > "$DIR/ai.fallback.batch"
    batch_apply "$DIR/ai.batch" 'AI-защита: ошибка ip -batch; перехожу на prohibit' "$DIR/ai.fallback.batch" || return 1
    rule_ensure $AI_PRIO $AI_TABLE || { log 'AI-защита: не удалось добавить ip rule'; return 1; }
    flush_cache
    ai_ok || { log 'AI-защита: маршруты не прошли проверку'; return 1; }
    ip route show table $AI_TABLE | awk '$1 == "prohibit" {print $2; next} {print $1}' | sort -u > "$DIR/ai.routes.existing"
    while read -r p; do
        [ -n "$p" ] || continue
        p=${p%/32}
        if ! grep -qxF "$p" "$AI_RESOLVED"; then
            ip route del "$p" metric 10 table $AI_TABLE 2>/dev/null
            ip route del "$p" metric 100 table $AI_TABLE 2>/dev/null
        fi
    done < "$DIR/ai.routes.existing"
    flush_cache
}
ai_off() {
    rc=0
    rule_remove $AI_PRIO $AI_TABLE || rc=1
    flush_table "$AI_TABLE" || rc=1
    flush_cache
    return "$rc"
}

# shellcheck shell=sh
# ---------- политики отдельных устройств ----------

valid_ipv4() {
    awk -v ip="$1" 'BEGIN {
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
        split(ip,o,"."); for (i=1;i<=4;i++) if (o[i] < 0 || o[i] > 255) exit 1
    }'
}
device_entries() {
    [ -f "$DEVICES_FILE" ] || return 0
    awk -F'|' 'NF {
        if (NF == 3) print $1 "|" $2 "|primary|" $3
        else if (NF == 4) print
        else if (NF == 5) print $1 "|" $2 "|" $3 "|" $5
    }' "$DEVICES_FILE"
}
devices_validate() {
    [ -f "$DEVICES_FILE" ] || return 0
    awk -F'|' '
        NF == 0 { next }
        NF != 3 && NF != 4 && NF != 5 { exit 1 }
        $1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { exit 1 }
        { split($1,o,"."); for (i=1;i<=4;i++) if (o[i] < 0 || o[i] > 255) exit 1 }
        $2 !~ /^(direct|vpn|vpn-all|vpn-list)$/ { exit 1 }
        NF >= 4 && $3 != "primary" && $3 != "secondary" { exit 1 }
        seen[$1]++ { exit 1 }
    ' "$DEVICES_FILE"
}
device_table_for() {
    case "$1:$2" in
        direct:*) echo "$DEV_DIRECT_TABLE" ;;
        vpn:primary) echo "$DEV_VPN_TABLE" ;;
        vpn:secondary) echo "$DEV_VPN2_TABLE" ;;
        vpn-all:primary) echo "$DEV_ALL_TABLE" ;;
        vpn-all:secondary) echo "$DEV_ALL2_TABLE" ;;
        vpn-list:primary) echo "$DEV_LIST_TABLE" ;;
        vpn-list:secondary) echo "$DEV_LIST2_TABLE" ;;
    esac
}
device_table_spec() {
    case "$1" in
        "$DEV_VPN_TABLE") echo 'vpn|primary' ;;
        "$DEV_VPN2_TABLE") echo 'vpn|secondary' ;;
        "$DEV_ALL_TABLE") echo 'vpn-all|primary' ;;
        "$DEV_ALL2_TABLE") echo 'vpn-all|secondary' ;;
    esac
}
device_if_vars() {
    if [ "$1" = secondary ]; then
        echo "$VPN2_IF|$VPN2_SERVERS_EXTRA|$VPN2_PROCESS"
    else
        echo "$VPN_IF|$VPN_SERVERS_EXTRA|$VPN_PROCESS"
    fi
}

# У каждого префикса есть постоянный prohibit: при удалении VPN-интерфейса
# ядро снимает маршрут через туннель, но не может перейти на WAN по умолчанию.
device_list_table() (
    table=$1; iface=$2; live=$3; wan=$4; failed=0
    batch=$DIR/devices.$table.batch
    source_file=$VPN_LIST; [ -f "$source_file" ] || source_file=/dev/null
    source_sum=$(sha256sum < "$source_file") || exit 1
    if [ ! -f "$DIR/vpn.resolved" ] || [ "$source_sum" != "$(cat "$DIR/vpn.source.sum" 2>/dev/null)" ]; then
        refresh_vpn_list || exit 1
    fi
    desired=$(
        echo "prohibit default metric 100"
        for p in $PRIVATE; do echo "throw $p"; done
        awk -v private="$PRIVATE" -v iface="$iface" -v live="$live" '
            function number(ip, a) { split(ip,a,"."); return ((a[1]*256+a[2])*256+a[3])*256+a[4] }
            function routes(p) {
                print "prohibit " p " metric 100"
                if (live && iface != "") print p " dev " iface " metric 10"
            }
            BEGIN {
                n=split(private,nets,/[[:space:]]+/)
                for(i=1;i<=n;i++) { split(nets[i],a,"/"); base[i]=number(a[1]); size[i]=2^(32-a[2]) }
            }
            NF {
                split($1,a,"/"); ip=number(a[1]); span=2^(32-(a[2]=="" ? 32 : a[2]))
                for(i=1;i<=n;i++) if(span<=size[i] && ip>=base[i] && ip<base[i]+size[i]) next
                if(span==2^32) { routes("0.0.0.0/1"); routes("128.0.0.0/1"); next }
                sub(/\/32$/, "", $1); routes($1)
            }' "$DIR/vpn.resolved" || exit 1
        if [ -n "$wan" ]; then echo "default $wan metric 10"; fi
    ) || exit 1

    current=$(table_routes "$table") || exit 1
    # ip route show добавляет scope, proto и src; сравниваем только поля нашей политики.
    if { printf '%s\n' "$desired"; echo "==="; printf '%s\n' "$current"; } | awk '
        $0=="===" { actual=1; next }
        !actual { want[$0]=1; next }
        NF {
            route=$1; if ($1=="prohibit" || $1=="throw") route=route " " $2
            sub(/\/32$/, "", route)
            for(i=2;i<NF;i++) if ($i=="via" || $i=="dev" || $i=="metric") route=route " " $i " " $(i+1)
            if (!(route in want)) extra=1
            delete want[route]
        }
        END { for (r in want) exit 1; exit extra+0 }
    '; then exit 0; fi
    printf '%s\n' "$desired" | awk -v t="$table" '{print "route replace " $0 " table " t}' > "$batch" || exit 1
    if ! reconcile_routes "$batch" "$table" 'устройства: ошибка применения списка VPN'; then
        ip route replace prohibit default metric 10 table "$table" || exit 1
        device_repair_table "$table" "" || exit 1
        failed=1
    fi
    # После смены маршрутов старые соединения этого устройства могли остаться в FASTNAT.
    device_entries | while IFS='|' read -r ipn policy vpn name; do
        [ "$policy" = vpn-list ] && [ "$(device_table_for "$policy" "$vpn")" = "$table" ] || continue
        if command -v conntrack >/dev/null 2>&1; then conntrack -D -s "$ipn" >/dev/null 2>&1 || :; fi
    done
    [ "$failed" = 0 ]
)

device_build_table() {
    t=$1; primary_ok=$2; secondary_ok=$3
    wan_route=$4
    spec=$(device_table_spec "$t")
    if [ -z "$spec" ]; then
        kind=direct
        [ -n "$wan_route" ] || { log "устройства: нет маршрута по умолчанию на $ISP_IF"; return 1; }
    else
        IFS='|' read -r kind vpn <<EOF
$spec
EOF
        vars=$(device_if_vars "$vpn"); IFS='|' read -r ifn extra proc <<EOF
$vars
EOF
        selected_ok=$primary_ok; [ "$vpn" = secondary ] && selected_ok=$secondary_ok
        [ -n "$ifn" ] || selected_ok=0
        servers=
        [ "$selected_ok" = 1 ] && servers=$(vpn_servers "$ifn" "$extra" "$proc")
        [ "$selected_ok" = 1 ] && [ -z "$servers" ] && selected_ok=0
        [ "$kind" = vpn-all ] || { [ -s "$RU_LIST" ] || download || log 'устройства: список РФ недоступен, российское для VPN-устройств тоже будет заблокировано'; }
    fi
    {
        echo "route replace prohibit default metric 100 table $t"
        for p in $PRIVATE; do echo "route replace throw $p table $t"; done
        if [ "$kind" = direct ]; then
            echo "route replace default $wan_route metric 10 table $t"
        else
            for s in $servers; do [ -n "$wan_route" ] && echo "route replace $s/32 $wan_route table $t"; done
            [ "$kind" = vpn ] && [ -n "$wan_route" ] && [ -s "$RU_LIST" ] && isp_prefix_routes "$wan_route" "$t" "$RU_LIST"
            [ "$selected_ok" = 1 ] && echo "route replace default dev $ifn metric 10 table $t"
        fi
    } > "$DIR/devices.$t.batch"
    reconcile_routes "$DIR/devices.$t.batch" "$t" "устройства: ошибка ip -batch для table $t" || return 1
    table_routes $t | grep -q '^prohibit default' || return 1
    table_routes $t | grep -q '^throw' || return 1
}
device_tables_ok() {
    t=$1; primary_ok=$2; secondary_ok=$3
    spec=$(device_table_spec "$t")
    if [ -z "$spec" ]; then
        [ -n "$4" ] && table_routes "$t" | awk -v hop="$4" '
            $1 == "default" { $1=$1; if (index($0 " ", "default " hop " ") == 1) found=1 }
            END { exit !found }'
        return
    fi
    table_routes "$t" | grep -q '^prohibit default' || return 1
    table_routes "$t" | grep -q '^throw' || return 1
    IFS='|' read -r kind vpn <<EOF
$spec
EOF
    vars=$(device_if_vars "$vpn"); IFS='|' read -r ifn extra proc <<EOF
$vars
EOF
    selected_ok=$primary_ok; [ "$vpn" = secondary ] && selected_ok=$secondary_ok
    if [ "$selected_ok" = 1 ] && [ -n "$ifn" ]; then
        table_routes "$t" | grep -q "^default dev $ifn .*metric 10" || return 1
    else
        if table_routes "$t" | grep -q '^default dev '; then return 1; fi
    fi
}
device_repair_table() {
    t=$1; wan_route=$2
    spec=$(device_table_spec "$t")
    {
        echo "route replace prohibit default metric 100 table $t"
        for p in $PRIVATE; do echo "route replace throw $p table $t"; done
        [ -z "$spec" ] && [ -n "$wan_route" ] && echo "route replace default $wan_route metric 10 table $t"
    } > "$DIR/devices.$t.fallback.batch"
    reconcile_routes "$DIR/devices.$t.fallback.batch" "$t" "устройства: ошибка fallback для table $t" || return 1
    table_routes "$t" | grep -q '^prohibit default' && table_routes "$t" | grep -q '^throw'
}
devices_ok() {
    priority_available "$DEV_PRIO" "$DEV_DIRECT_TABLE" || return 1
    [ "$(device_entries | wc -l)" -eq "$(ip rule show | grep -c "^$DEV_PRIO:")" ] || return 1
    device_entries | while IFS='|' read -r ipn policy vpn name; do
        t=$(device_table_for "$policy" "$vpn")
        rule_status "$DEV_PRIO" "$t" "from $ipn" || exit 1
    done
}
device_apply() {
    devices_validate || { log 'устройства: devices.conf содержит ошибку или дублирующийся IP; прежние правила сохранены'; return 1; }
    : > "$DIR/devices.rules.new"
    device_entries | while IFS='|' read -r ipn policy vpn name; do
        echo "$ipn|$(device_table_for "$policy" "$vpn")"
    done | sort -u > "$DIR/devices.rules.new"
    mv "$DIR/devices.rules.new" "$DIR/devices.rules"
    priority_available "$DEV_PRIO" "$DEV_DIRECT_TABLE" || return 1
    needed=$(awk -F'|' '{print $2}' "$DIR/devices.rules" | sort -u | tr '\n' ' ')
    primary_ok=0; secondary_ok=0
    if [ -n "$needed" ]; then
        tunnel_ok "$VPN_IF" && primary_ok=1
        [ -n "$VPN2_IF" ] && tunnel_ok "$VPN2_IF" && secondary_ok=1
    fi
    wan_route=$(isp_nexthop)
    want="$(isp_route_state "$wan_route") primary_ok=$primary_ok secondary_ok=$secondary_ok servers=$(echo $(vpn_servers)) servers2=$(echo $(vpn_servers "$VPN2_IF" "$VPN2_SERVERS_EXTRA" "$VPN2_PROCESS")) ru=$(date -r "$RU_LIST" +%s 2>/dev/null) devices=$(date -r "$DEVICES_FILE" +%s 2>/dev/null)"
    rebuild=0
    [ "$want" = "$(cat "$DIR/devices.state" 2>/dev/null)" ] || rebuild=1
    other_tables=
    for t in $needed; do
        case "$t" in
            "$DEV_LIST_TABLE") device_list_table "$t" "$VPN_IF" "$primary_ok" "$wan_route" || return 1 ;;
            "$DEV_LIST2_TABLE") device_list_table "$t" "$VPN2_IF" "$secondary_ok" "$wan_route" || return 1 ;;
            *) other_tables="$other_tables $t"; device_tables_ok "$t" "$primary_ok" "$secondary_ok" "$wan_route" || rebuild=1 ;;
        esac
    done
    if [ "$rebuild" = 1 ]; then
        for t in $other_tables; do
            if ! device_build_table "$t" "$primary_ok" "$secondary_ok" "$wan_route"; then
                device_repair_table "$t" "$wan_route" || return 1
                [ -n "$(device_table_spec "$t")" ] || return 1
            fi
        done
    fi
    tables_re=$(echo "$DEV_TABLES" | tr ' ' '|')
    ip rule show | awk -v p="$DEV_PRIO:" -v re="^($tables_re)$" '$1 == p && $5 ~ re {print $3 "|" $5}' > "$DIR/devices.rules.existing"
    while IFS='|' read -r ipn t; do
        [ -n "$ipn" ] || continue
        rule_ensure $DEV_PRIO "$t" "from $ipn" || return 1
    done < "$DIR/devices.rules"
    while IFS='|' read -r ipn t; do
        grep -qxF "$ipn|$t" "$DIR/devices.rules" || rule_remove $DEV_PRIO "$t" "from $ipn" || return 1
    done < "$DIR/devices.rules.existing"
    for t in $DEV_TABLES; do
        echo " $needed " | grep -q " $t " || flush_table "$t" || return 1
    done
    echo "$want" > "$DIR/devices.state"
    flush_cache
}
device_clear() {
    priority_available "$DEV_PRIO" "$DEV_DIRECT_TABLE" || return 1
    rc=0
    tables_re=$(echo "$DEV_TABLES" | tr ' ' '|')
    ip rule show | awk -v p="$DEV_PRIO:" -v re="^($tables_re)$" '$1 == p && $5 ~ re {print $3 "|" $5}' > "$DIR/devices.rules.existing"
    while IFS='|' read -r ipn t; do rule_remove $DEV_PRIO "$t" "from $ipn" || rc=1; done < "$DIR/devices.rules.existing"
    for t in $DEV_TABLES; do flush_table "$t" || rc=1; done
    rm -f "$DIR/devices.state"
    flush_cache
    return "$rc"
}
# Сначала применяем новый набор политик. Постоянная конфигурация меняется
# атомарно, только когда все таблицы и правила уже установлены.
device_commit() (
    previous_file=$DEVICES_FILE
    DEVICES_FILE=$1
    if device_apply && mv "$1" "$previous_file"; then
        DEVICES_FILE=$previous_file
        if [ "$CAPTIVE_STUB" = 1 ] && [ -f "$KILL_FLAG" ]; then
            captive_on || { captive_off; log 'не удалось обновить HTTP-заглушку после изменения правила устройства'; }
        fi
        flush_flows
        return 0
    fi
    DEVICES_FILE=$previous_file
    device_apply || log 'устройства: не удалось повторно применить прежние правила'
    rm -f "$1"
    return 1
)
device_set() {
    ipn=$1; policy=$2; a3=${3:-}; a4=${4:-}; a5=${5:-}
    devices_validate || { echo 'devices.conf содержит ошибку, исправьте файл вручную' >&2; return 1; }
    valid_ipv4 "$ipn" || { echo 'некорректный IPv4-адрес устройства' >&2; return 1; }
    case "$policy" in default|direct|vpn|vpn-all|vpn-list) ;; *) echo 'политика: default|direct|vpn|vpn-all|vpn-list' >&2; return 1 ;; esac
    case "$a3" in
        primary|secondary)
            vpn=$a3
            if { [ "$a4" = 0 ] || [ "$a4" = 1 ]; } && [ -n "$a5" ]; then name=$a5; else name=$a4; fi ;;
        *) vpn=primary; name=$a3 ;;
    esac
    [ "$vpn" != secondary ] || [ -n "$VPN2_IF" ] || { echo 'дополнительный VPN не настроен' >&2; return 1; }
    name=$(printf '%s' "$name" | tr -d '|\r\n' | head -c 80)
    source_file=$DEVICES_FILE; [ -f "$source_file" ] || source_file=/dev/null
    awk -F'|' -v ip="$ipn" '$1 != ip' "$source_file" > "$DIR/devices.conf.new" || return 1
    [ "$policy" = default ] || printf '%s|%s|%s|%s\n' "$ipn" "$policy" "$vpn" "$name" >> "$DIR/devices.conf.new" || return 1
    sort "$DIR/devices.conf.new" > "$DIR/devices.conf.sorted" || return 1
    rm -f "$DIR/devices.conf.new"
    device_commit "$DIR/devices.conf.sorted" || return 1
    log "устройство $ipn ($name): политика $policy, VPN $vpn"
}
device_del() {
    devices_validate || return 1
    valid_ipv4 "$1" || return 1
    [ -f "$DEVICES_FILE" ] || return 0
    awk -F'|' -v ip="$1" '$1 != ip' "$DEVICES_FILE" > "$DIR/devices.conf.new" || return 1
    device_commit "$DIR/devices.conf.new" || return 1
    log "устройство $1: индивидуальная политика удалена"
}

rule_on() {
    rule_is_on && return 0
    rule_ensure $PRIO $TABLE || return 1
    flush_cache; flush_flows
}
rule_off() {
    rule_status "$PRIO" "$TABLE" "" exact || { [ "$?" = 1 ]; return; }
    rule_remove $PRIO $TABLE || return 1
    flush_cache; flush_flows
}
rule_is_on() { rule_status "$PRIO" "$TABLE"; }
table_ok() { table_routes $TABLE | grep -q "^default dev $VPN_IF"; }
# shellcheck shell=sh
# ---------- ручные списки ----------

# подсети автономной системы: кэш на сутки, качаем с RIPEstat (сначала через VPN)
asn_prefixes() {
    a=$(echo "$1" | tr 'a-z' 'A-Z'); f=$ASN_DIR/$a.cidr
    mkdir -p "$ASN_DIR"
    age=$(( $(date +%s) - $(date -r "$f" +%s 2>/dev/null || echo 0) ))
    if [ ! -s "$f" ] || [ "$age" -gt "$ASN_TTL" ] || [ -n "${ASN_REFRESH:-}" ]; then
        for via in "--interface $VPN_IF" ""; do
            if curl -sf -m 60 $via "$ASN_API$a" -o "$f.json" 2>/dev/null; then
                grep -oE '"prefix": ?"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+"' "$f.json" | grep -oE '[0-9.]+/[0-9]+' | sort -u > "$f.new"
                if [ -s "$f.new" ]; then mv "$f.new" "$f"; log "$a: $(wc -l < "$f") подсетей (RIPEstat)"; break; fi
                log "$a: RIPEstat не вернул подсетей IPv4"
            fi
        done
        rm -f "$f.json" "$f.new"
        [ -s "$f" ] || log "$a: не удалось получить подсети"
    fi
    [ -f "$f" ] && cat "$f"
}

# записи списка -> строки «адрес запись» (домены резолвятся сейчас, AS раскрываются в подсети)
list_map() {
    [ -f "$1" ] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$' | while read -r e; do
        if echo "$e" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'; then echo "$e $e"
        elif echo "$e" | grep -qiE '^AS[0-9]+$'; then asn_prefixes "$e" | sed "s|\$| $(echo "$e" | tr 'a-z' 'A-Z')|"
        else resolve "$e" | sed "s|\$| $e|"; fi
    done
}

# При временной ошибке DNS или RIPEstat сохраняем адреса только для оставшихся в списке записей.
refresh_vpn_list() (
    source_file=$VPN_LIST; [ -f "$source_file" ] || source_file=/dev/null
    cp "$source_file" "$DIR/vpn.source.new" || exit 1
    list_map "$DIR/vpn.source.new" > "$DIR/vpn.fresh" || exit 1
    previous=$DIR/vpn.map; [ -f "$previous" ] || previous=/dev/null
    : > "$DIR/vpn.missing.new" || exit 1
    awk -v missing="$DIR/vpn.missing.new" '
        FILENAME==ARGV[1] {
            sub(/#.*/, ""); gsub(/[[:space:]]/, "")
            if (tolower($0) ~ /^as[0-9]+$/) $0=toupper($0)
            if (length($0)) needed[$0]=1
            next
        }
        FILENAME==ARGV[2] { fresh[$2]=1; print; next }
        ($2 in needed) && !($2 in fresh) { cached[$2]=1; print }
        END { for (e in needed) if (!(e in fresh) && !(e in cached)) print e > missing }
    ' "$DIR/vpn.source.new" "$DIR/vpn.fresh" "$previous" > "$DIR/vpn.map.new" || exit 1
    awk '{print $1}' "$DIR/vpn.map.new" | sort -u > "$DIR/vpn.resolved.new" || exit 1
    sha256sum < "$DIR/vpn.source.new" > "$DIR/vpn.source.sum.new" || exit 1
    for f in vpn.map vpn.resolved vpn.missing vpn.source.sum; do mv "$DIR/$f.new" "$DIR/$f" || exit 1; done
    rm -f "$DIR/vpn.source.new" "$DIR/vpn.fresh"
)

build_force() {
    priority_available "$FORCE_PRIO" "$FORCE_TABLE" || return 1
    wan_route=$(isp_nexthop)
    [ -n "$wan_route" ] || { log "списки: нет маршрута по умолчанию на $ISP_IF"; return 1; }
    wan_state=$(isp_route_state "$wan_route")
    list_map "$DIRECT_LIST" > "$DIR/direct.map"
    refresh_vpn_list || return 1
    awk '{print $1}' "$DIR/direct.map" | sort -u > "$DIR/direct.resolved"
    {
        isp_prefix_routes "$wan_route" "$FORCE_TABLE" "$DIR/direct.resolved"
        if [ -f "$KILL_FLAG" ] && [ "${1:-}" != normal ]; then
            grep -vxF -f "$DIR/direct.resolved" "$DIR/vpn.resolved" | awk -v t="$FORCE_TABLE" '{print "route replace prohibit " $1 " table " t}'
        elif ip link show "$VPN_IF" >/dev/null 2>&1; then
            grep -vxF -f "$DIR/direct.resolved" "$DIR/vpn.resolved" | awk -v d="$VPN_IF" -v t="$FORCE_TABLE" '{print "route replace " $1 " dev " d " table " t}'
        fi
    } > "$DIR/force.batch"
    reconcile_routes "$DIR/force.batch" "$FORCE_TABLE" 'списки: ошибки ip -batch' || return 1
    n=$(table_count "$FORCE_TABLE") || return 1
    rule_ensure $FORCE_PRIO $FORCE_TABLE || { log 'списки: не удалось добавить ip rule'; return 1; }
    echo "$n $wan_state" > "$FORCE_STATE"
    flush_cache
    log "ручные списки: $(wc -l < "$DIR/direct.resolved") адресов напрямую, $(wc -l < "$DIR/vpn.resolved") через VPN (маршрутов $n)"
    return 0
}
# маршруты списков пропадают, когда VPN-интерфейс пересоздаётся
force_ok() {
    rule_status "$FORCE_PRIO" "$FORCE_TABLE" || return 1
    [ -r "$FORCE_STATE" ] && read -r want saved_wan < "$FORCE_STATE" || return 1
    [ "$saved_wan" = "$(isp_route_state "$(isp_nexthop)")" ] || return 1
    actual=$(table_count "$FORCE_TABLE") || return 1
    [ "$actual" -ge "$want" ]
}
force_off() {
    rule_remove $FORCE_PRIO $FORCE_TABLE || return 1
    flush_table "$FORCE_TABLE" || return 1
    flush_cache
}

# shellcheck shell=sh
# ---------- kill switch ----------
#
# Блокирует маршрутизация — без правил в FORWARD и без хука netfilter.d. Прежняя версия (до 15.10)
# при упавшем туннеле включалась на недостроенной таблице 1022: ответы в домашнюю сеть уходили провайдеру,
# и роутер «пропадал» из сети целиком.
#   - table 1022: default -> prohibit (зарубежное с устройств сразу получает отказ от ядра);
#   - записи «через VPN» из ручных списков -> тоже prohibit (не висеть в мёртвом туннеле);
#   - ip rule iif lo -> main (трафик самого роутера — DNS, переподключение VPN — напрямую);
#   - заглушка (только если CAPTIVE_STUB=1, по умолчанию выключена): одно правило nat — tcp/80 на
#     зарубежные адреса -> страница-заглушка. На неё попадают проверки интернета (captive portal), и
#     iPhone/Mac считают сеть «требующей входа» — до «входа» они не пускают через Wi‑Fi вообще ничего,
#     включая российское (проверено 15.10). Поэтому по умолчанию — только мгновенный отказ.
#   - страховка: ip rule to <частные сети> lookup main (prio 30018) — домашняя сеть и роутер доступны
#     при любом состоянии наших таблиц.

KILL_PRIO=30019
CAPTIVE_CHAIN=RAZVILKA_CAPTIVE

# ipset «не трогать заглушкой»: сети РФ + «напрямую» + VPN-сервер + DNS + частные сети.
# Нужен только для одного правила nat (tcp/80 на зарубежные адреса -> заглушка): IP служебных адресов
# проверки интернета (captive.apple.com, connectivitycheck.gstatic.com...) меняются постоянно, списком
# конкретных IP их не поймать. Блокирует при этом маршрутизация, не iptables.
build_set() {
    {
        echo "create ${SET}_tmp hash:net maxelem 131072 -exist"
        echo "flush ${SET}_tmp"
        for p in $PRIVATE; do echo "add ${SET}_tmp $p -exist"; done
        for r in $RESOLVERS; do echo "add ${SET}_tmp $r -exist"; done
        for v in $(vpn_servers); do echo "add ${SET}_tmp $v -exist"; done
        awk '{print "add '"${SET}"'_tmp " $1 " -exist"}' "$RU_LIST"
        [ -f "$DIR/direct.resolved" ] && awk '{print "add '"${SET}"'_tmp " $1 " -exist"}' "$DIR/direct.resolved"
    } > "$DIR/ipset.restore"
    ipset create $SET hash:net maxelem 131072 -exist
    ipset restore < "$DIR/ipset.restore" && ipset swap ${SET}_tmp $SET && ipset destroy ${SET}_tmp
}

captive_on() {
    [ "$CAPTIVE_STUB" = 1 ] || { captive_off; return 0; }
    command -v ipset >/dev/null 2>&1 || return 0
    # пустой или битый набор = заглушка перехватила бы и российские http-сайты — тогда без заглушки
    build_set || { log "заглушка: не собрался ipset — без неё"; captive_off; return 0; }
    [ "$(grep -c '^add' "$DIR/ipset.restore")" -gt 1000 ] || { log "заглушка: в наборе подозрительно мало сетей — без неё"; captive_off; return 0; }
    iptables -t nat -N $CAPTIVE_CHAIN 2>/dev/null
    iptables -t nat -F $CAPTIVE_CHAIN
    # У телевизора с прямым выходом HTTP к зарубежному видеосерверу тоже идёт по политике устройства.
    device_entries | while IFS='|' read -r ipn policy vpn name; do
        [ "$policy" = vpn-list ] || continue
        valid_ipv4 "$ipn" && iptables -t nat -A "$CAPTIVE_CHAIN" -s "$ipn" -j RETURN || exit 1
    done || { captive_off; return 1; }
    iptables -t nat -A $CAPTIVE_CHAIN -p tcp -m set ! --match-set $SET dst -j DNAT --to-destination "$LAN_IP:$STUB_PORT"
    iptables -t nat -C PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN 2>/dev/null \
        || iptables -t nat -I PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN
}
captive_off() {
    while iptables -t nat -C PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN 2>/dev/null; do
        iptables -t nat -D PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN || return 1
    done
    iptables -t nat -F $CAPTIVE_CHAIN 2>/dev/null; iptables -t nat -X $CAPTIVE_CHAIN 2>/dev/null
    ipset destroy $SET 2>/dev/null
    return 0
}

# остатки реализации до 15.10 (ipset + REJECT в FORWARD) — снимаем, если вдруг есть
legacy_kill_off() {
    for r in "nat PREROUTING -i $LAN_IF -p tcp --dport 80 -m set ! --match-set $SET dst -j DNAT --to-destination $LAN_IP:$STUB_PORT" \
             "filter FORWARD -i $LAN_IF -p tcp -m set ! --match-set $SET dst -j REJECT --reject-with tcp-reset" \
             "filter FORWARD -i $LAN_IF -m set ! --match-set $SET dst -j REJECT --reject-with icmp-net-unreachable"; do
        t=${r%% *}; rule=${r#* }
        while iptables -t "$t" -C $rule 2>/dev/null; do iptables -t "$t" -D $rule || return 1; done
    done
    ipset destroy $SET 2>/dev/null
    return 0
}

kill_on() {
    priority_available "$PRIO" "$TABLE" || return 1
    guard_on || return 1
    rule_ensure "$KILL_PRIO" main 'iif lo' || return 1
    echo "route replace prohibit default table $TABLE" > "$DIR/kill.guard.batch"
    batch_apply "$DIR/kill.guard.batch" 'kill switch: не удалось установить prohibit' || return 1
    rule_ensure "$PRIO" "$TABLE" || return 1
    kill_mode=$(failmode)
    wan_route=$(isp_nexthop)
    kill_signature=$(printf '%s\n' "$kill_mode" "$(isp_route_state "$wan_route")" "$(vpn_servers)"
        [ ! -f "$RU_LIST" ] || sha256sum "$RU_LIST"
        [ "$kill_mode" != soft ] || [ ! -f "$DIR/allow.resolved" ] || sha256sum "$DIR/allow.resolved")
    kill_changed=0
    if [ "$kill_signature" != "$(cat "$KILL_FLAG" 2>/dev/null)" ] || ! table_routes "$TABLE" | grep -q '^throw '; then
        build down || return 1
        kill_changed=1
    fi
    {
        echo "route replace prohibit default table $TABLE"
        # мягкий kill: разрешённое (CDN, шрифты, капча, свои записи) — напрямую
        [ "$kill_mode" = soft ] && [ -n "$wan_route" ] && [ -f "$DIR/allow.resolved" ] \
            && isp_prefix_routes "$wan_route" "$TABLE" "$DIR/allow.resolved"
        # публичные DNS — напрямую: иначе устройства с «зашитым» DNS (Android, Chromecast, ноутбуки)
        # потеряют и российские сайты
        [ -n "$wan_route" ] && for r in $RESOLVERS; do echo "route replace $r $wan_route table $TABLE"; done
        [ -f "$DIR/vpn.resolved" ] && grep -vxF -f "$DIR/direct.resolved" "$DIR/vpn.resolved" 2>/dev/null \
            | awk -v t="$FORCE_TABLE" '{print "route replace prohibit " $1 " table " t}'
    } > "$DIR/kill.batch"
    batch_apply "$DIR/kill.batch" 'kill switch: ошибка ip -batch' || return 1
    flush_cache
    captive_on || return 1
    if [ "$kill_changed" = 1 ]; then
        printf '%s\n' "$kill_signature" > "$KILL_FLAG" || return 1
        flush_flows
        log "kill switch: $kill_mode"
    fi
    return 0
}

kill_off() {
    captive_off
    rule_remove "$KILL_PRIO" main 'iif lo' || return 1
    if [ -f "$KILL_FLAG" ]; then
        case "${1:-live}" in
            live) build || return 1; build_force normal || return 1 ;;
            direct) rule_off || return 1; build_force normal || return 1 ;;
            stop) : ;;
        esac
        rm -f "$KILL_FLAG"
        flush_cache; flush_flows
        log "kill switch выкл"
    fi
}
killtest_active() { [ -f "$TEST_UNTIL" ] && [ "$(date +%s)" -lt "$(cat "$TEST_UNTIL")" ]; }

# ---------- страница-заглушка ----------

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

make_stub() {
    mkdir -p "$DIR/stub"
    c=$(cat "$CONTACT" 2>/dev/null | html_escape | sed 's/$/<br>/')
    [ -z "$c" ] && c="Обратитесь к тому, кто настраивал VPN на этом роутере."
    cat > "$DIR/stub/index.html" <<EOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Доступ к сайту ограничен</title>
<style>
:root{--bg:#fbf6ee;--card:#fff;--fg:#2a2622;--mut:#6b625a;--line:#efe5d8;--accent:#e07a3f;
--scr:#ffe3c9;--tv:#f2a46b;--tvd:#c9733d;--face:#7a4a2a;--blob:#fde9d4;
--okb:#e7f5ea;--okl:#cfe9d6;--okf:#1d6b37;--chip:#fff;
--help:#fff3d6;--helpl:#f3dfab;--helpf:#5e4610;
--calm:#eaf1fb;--calmf:#2a4a74;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#1a1714;--card:#24201c;--fg:#f3ece4;--mut:#bfb3a6;--line:#3a332c;--accent:#f0a273;
--scr:#4a3627;--tv:#c98552;--tvd:#9c6237;--face:#ffd9b8;--blob:#2c241d;
--okb:#16291c;--okl:#24432d;--okf:#9be0b0;--chip:#1d2a20;
--help:#33290f;--helpl:#4c3e19;--helpf:#ffe29a;
--calm:#1b2534;--calmf:#bcd4f5;color-scheme:dark}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;min-height:100vh;background:#fbf6ee;background:var(--bg);color:#2a2622;color:var(--fg);
font:19px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
main{max-width:640px;margin:0 auto;padding:28px 16px 40px}
.card{background:#fff;background:var(--card);border:1px solid var(--line);border-radius:28px;padding:28px 24px;
box-shadow:0 2px 4px rgba(60,40,20,.04),0 18px 48px -20px rgba(60,40,20,.22)}
.ill{display:block;width:200px;max-width:70%;height:auto;margin:0 auto 8px}
.ill .blob{fill:var(--blob)}.ill .tv{fill:var(--tv)}.ill .tvd{fill:var(--tvd)}.ill .scr{fill:var(--scr)}
.ill .ln{fill:none;stroke:var(--tvd);stroke-width:4;stroke-linecap:round}
.ill .face{fill:none;stroke:var(--face);stroke-width:3.5;stroke-linecap:round}
.ill .cheek{fill:var(--accent);opacity:.35}
.ill .zz{fill:var(--accent);font:700 18px/1 -apple-system,"Segoe UI",Roboto,sans-serif}
.zz1{animation:float 3.2s ease-in-out infinite}.zz2{animation:float 3.2s ease-in-out .8s infinite}
@keyframes float{0%,100%{transform:translateY(0);opacity:.9}50%{transform:translateY(-5px);opacity:.5}}
h1{font-size:28px;line-height:1.25;margin:6px 0 10px;text-align:center;letter-spacing:-.01em}
.lead{text-align:center;font-size:21px;margin:0 0 6px}
.lead b{color:var(--okf)}
.soft{text-align:center;color:#6b625a;color:var(--mut);margin:0 0 22px}
.box{border-radius:20px;padding:18px 20px;margin:0 0 14px}
.box h2{font-size:20px;line-height:1.3;margin:0 0 10px}
.ok{background:#e7f5ea;background:var(--okb);border:1px solid var(--okl)}
.ok h2{color:var(--okf)}
.chips{margin:0;padding:0;list-style:none}
.chips li{display:inline-block;margin:0 6px 8px 0;padding:6px 14px;border-radius:999px;background:var(--chip);border:1px solid var(--okl);font-weight:600}
.calm{background:var(--calm);color:var(--calmf)}
.calm p{margin:0}
.help{background:#fff3d6;background:var(--help);border:2px solid var(--helpl);color:var(--helpf)}
.help h2{color:var(--helpf)}
.who{font-size:22px;font-weight:700;line-height:1.45;color:var(--fg);overflow-wrap:break-word}
.who a{color:inherit}
.ic{display:inline-block;vertical-align:-4px;margin-right:8px}
small{display:block;text-align:center;color:var(--mut);font-size:14px;margin-top:20px}
@media (min-width:700px){main{padding-top:6vh}.card{padding:36px 40px}h1{font-size:34px}.ill{width:230px}}
@media (min-width:1280px){body{font-size:22px}main{max-width:760px}h1{font-size:40px}.lead{font-size:25px}.box h2{font-size:23px}.who{font-size:26px}.ill{width:270px}}
@media (prefers-reduced-motion:reduce){.zz1,.zz2{animation:none}}
</style></head><body><main><div class="card">
<svg class="ill" viewBox="0 0 200 170" role="img" aria-label="Телевизор спокойно отдыхает">
<circle class="blob" cx="100" cy="92" r="76"/>
<path class="ln" d="M80 30l20 18M120 30l-20 18"/>
<circle class="tvd" cx="80" cy="29" r="5"/><circle class="tvd" cx="120" cy="29" r="5"/>
<path class="ln" d="M70 140l-8 16M130 140l8 16"/>
<rect class="tv" x="36" y="48" width="128" height="94" rx="22"/>
<rect class="scr" x="50" y="61" width="100" height="68" rx="14"/>
<path class="face" d="M74 92q7 6 14 0M112 92q7 6 14 0M90 108q10 8 20 0"/>
<circle class="cheek" cx="72" cy="104" r="6"/><circle class="cheek" cx="128" cy="104" r="6"/>
<text class="zz zz1" x="152" y="40">z</text><text class="zz zz2" x="166" y="24" style="font-size:14px">z</text>
</svg>
<h1>Доступ к этому сайту ограничен</h1>
<p class="lead">На роутере включена <b>блокировка соединений без VPN</b>.</p>
<p class="soft">Такая страница появляется при сбое VPN или во время проверки блокировки.</p>

<div class="box ok">
<h2><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M7.5 12.5l3 3 6-6"/></svg>Какие сайты можно открыть</h2>
<p>Сайты с прямым маршрутом по-прежнему доступны через провайдера. Изображения или видео могут не загрузиться, если им нужен VPN.</p>
</div>

<div class="box calm">
<p><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9"/><path d="M12 7v5l3 2"/></svg>Когда роутер восстановит маршрут через VPN, <b>обновите страницу</b>. Перезагрузка устройства не требуется.</p>
</div>

<div class="box help">
<h2><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8l-4 3v-3H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z"/></svg>К кому обратиться</h2>
<div class="who">$c</div>
</div>

<small>Эту страницу показывает домашний роутер</small>
</div></main></body></html>
EOF
}

# shellcheck shell=sh
# ---------- сторож ----------

# отдельный адрес в домашней сети для http://razvilka.lan (на 80-м порту роутера живёт веб Keenetic)
alias_on() { [ -n "$ALIAS_IP" ] || return 0; ip -4 addr show br0 | grep -q " $ALIAS_IP/" || ip addr add "$ALIAS_IP/32" dev br0 2>/dev/null; return 0; }
alias_off() { [ -n "$ALIAS_IP" ] && ip addr del "$ALIAS_IP/32" dev br0 2>/dev/null; return 0; }

# когда туннель последний раз сменил состояние (для страницы статуса): «1|0 <epoch>»
TUNNEL_STATE=$DIR/tunnel_state
mark_tunnel() {
    date +%s > "$DIR/last_check"
    previous_tunnel=$(cut -d' ' -f1 "$TUNNEL_STATE" 2>/dev/null)
    [ "$previous_tunnel" != "$1" ] || return 0
    echo "$1 $(date +%s)" > "$TUNNEL_STATE" || return 1
    case "$previous_tunnel:$1" in
        *:0) log 'VPN не отвечает' ;;
        0:1) log 'Связь с VPN восстановлена' ;;
    esac
}

watchdog() {
    watchdog_rc=0
    alias_on || watchdog_rc=1
    ipv6_block_on || watchdog_rc=1
    # Первую проверку после загрузки не откладываем до второго опроса.
    if scheme_running && [ "$(failmode)" != direct ] && ! rule_is_on; then
        kill_on || watchdog_rc=1
    fi
    device_apply || watchdog_rc=1
    ai_apply || watchdog_rc=1
    if killtest_active; then
        kill_on || watchdog_rc=1
        return "$watchdog_rc"
    fi
    if ! scheme_running; then
        if [ -f "$TEST_UNTIL" ] || [ -f "$KILL_FLAG" ]; then stop_main service || watchdog_rc=1; fi
        return "$watchdog_rc"
    fi
    rm -f "$TEST_UNTIL"
    guard_on || watchdog_rc=1
    force_ok || build_force || watchdog_rc=1
    if tunnel_ok; then
        mark_tunnel 1
        echo 0 > "$FAILS"
        if [ -f "$KILL_FLAG" ]; then kill_off || return 1; fi
        captive_off
        want="$(isp_route_state "$(isp_nexthop)") servers=$(echo $(vpn_servers))"
        if ! table_ok || [ "$want" != "$(cat "$STATE" 2>/dev/null)" ]; then
            build || return 1
            build_force || watchdog_rc=1
        fi
        rule_on || watchdog_rc=1
    else
        f=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )); echo "$f" > "$FAILS"
        if [ "$f" -ge 2 ] || [ -f "$KILL_FLAG" ]; then
            mark_tunnel 0
            if [ "$(failmode)" != direct ]; then
                kill_on || watchdog_rc=1
            else
                kill_off direct || watchdog_rc=1
                rule_off || watchdog_rc=1
            fi
        fi
    fi
    return "$watchdog_rc"
}

# адрес попадает в подсеть из файла (одна подсеть на строку, первое поле)? -> печатает её поле 2
cidr_match() {  # cidr_match IP FILE [all]
    awk -v ip="$1" -v all="${3:-}" '
        function n(a,  p) { split(a, p, "."); return ((p[1]*256 + p[2])*256 + p[3])*256 + p[4] }
        BEGIN { x = n(ip) }
        { split($1, c, "/"); b = (c[2] == "" ? 32 : c[2]); s = 2 ^ (32 - b)
          if (int(x / s) == int(n(c[1]) / s)) { print ($2 == "" ? $1 : $2); if (all == "") exit } }' "$2" 2>/dev/null
}

# всё про адрес — для веб-морды: маршрут, в каких списках и по какой записи, РФ ли, чья AS
lookup() {
    if [ -n "${2:-}" ]; then
        valid_ipv4 "$2" || return 1
        ingress=$(ip route get "$2" 2>/dev/null | awk 'NR==1 {for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
        case "$LAN_IF" in
            *+) case "$ingress" in "${LAN_IF%+}"?*) ;; *) echo "scope=unknown"; return 1 ;; esac ;;
            *) [ "$ingress" = "$LAN_IF" ] || { echo "scope=unknown"; return 1; } ;;
        esac
        r=$(LC_ALL=C ip route get "$1" from "$2" iif "$ingress" 2>&1)
        echo "scope=client"
    else
        r=$(LC_ALL=C ip route get "$1" 2>&1)
        echo "scope=router"
    fi
    case "$r" in *"Permission denied"*|*prohibit*) echo "blocked=1" ;; *) echo "blocked=0" ;; esac
    dev=$(echo "$r" | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    tbl=$(echo "$r" | awk '{for(i=1;i<NF;i++) if($i=="table"){print $(i+1); exit}}')
    echo "dev=$dev"; echo "table=$tbl"
    for l in direct vpn; do cidr_match "$1" "$DIR/$l.map" all | sort -u | sed "s/^/match_$l=/"; done
    [ -n "$(cidr_match "$1" "$RU_LIST")" ] && echo "ru=1" || echo "ru=0"
    ai_is_on && [ -n "$(cidr_match "$1" "$AI_RESOLVED")" ] && echo "ai=1" || echo "ai=0"
    [ "${3:-}" != brief ] || return 0
    # чья сеть — RIPEstat (через VPN, коротко), имена AS кэшируются
    a=$(curl -sf -m 6 --interface "$VPN_IF" "https://stat.ripe.net/data/network-info/data.json?resource=$1" 2>/dev/null \
        | grep -oE '"asns": ?\[[^]]*\]' | grep -oE '[0-9]+' | head -1)
    if [ -n "$a" ]; then
        echo "asn=$a"
        h=$(grep "^$a " "$DIR/asn-names" 2>/dev/null | head -1 | cut -d' ' -f2-)
        if [ -z "$h" ]; then
            h=$(curl -sf -m 6 --interface "$VPN_IF" "https://stat.ripe.net/data/as-overview/data.json?resource=AS$a" 2>/dev/null \
                | grep -oE '"holder": ?"[^"]*"' | cut -d'"' -f4 | tr -cd 'A-Za-z0-9 .,()&/-' | cut -c1-60)
            [ -n "$h" ] && echo "$a $h" >> "$DIR/asn-names"
        fi
        echo "holder=$h"
    fi
}

# из какой записи ручного списка взялся адрес: «direct kion.ru» / «vpn AS32934»
why() {
    ai_is_on && [ -n "$(cidr_match "$1" "$AI_RESOLVED")" ] && { echo 'ai Claude Code / ChatGPT'; return; }
    for l in direct vpn; do
        [ -f "$DIR/$l.map" ] || continue
        awk -v ip="$1" -v l="$l" '
            function n(a,  p) { split(a, p, "."); return ((p[1]*256 + p[2])*256 + p[3])*256 + p[4] }
            BEGIN { x = n(ip) }
            { split($1, c, "/"); b = (c[2] == "" ? 32 : c[2]); s = 2 ^ (32 - b)
              if (int(x / s) == int(n(c[1]) / s)) { print l, $2; exit } }' "$DIR/$l.map"
    done | head -1
}

count_entries() { [ -f "$1" ] || { echo 0; return; }; sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -c .; }
# число строк в файле; нет файла -> 0. Именно так, а не «wc -l < файл 2>/dev/null»:
# busybox sh печатает ошибку неудачного редиректа в stderr, и 2>/dev/null команды её не подавляет
lines() { if [ -f "$1" ]; then wc -l < "$1"; else echo 0; fi; }

PROC_NET_DEV=${RZ_TEST_PROC_NET_DEV:-/proc/net/dev}
traffic_bytes() { awk -v ifn="$1" '$1 == ifn ":" {print $2 "|" $10}' "$PROC_NET_DEV" 2>/dev/null; }

doctor_ok() { echo "OK: $*"; }
doctor_warn() { echo "WARN: $*"; }
doctor_fail() { echo "FAIL: $*"; DOCTOR_FAIL=1; }
doctor() {
    DOCTOR_FAIL=0
    if ip link show "$VPN_IF" >/dev/null 2>&1; then doctor_ok "VPN-интерфейс $VPN_IF существует"; else doctor_fail "VPN-интерфейс $VPN_IF отсутствует"; fi
    if tunnel_ok; then doctor_ok 'VPN-туннель отвечает на проверки'; else doctor_warn 'VPN-туннель не отвечает на проверки'; fi
    if [ -n "$VPN2_IF" ]; then
        ip link show "$VPN2_IF" >/dev/null 2>&1 && doctor_ok "дополнительный VPN-интерфейс $VPN2_IF существует" || doctor_fail "дополнительный VPN-интерфейс $VPN2_IF отсутствует"
        tunnel_ok "$VPN2_IF" && doctor_ok 'дополнительный VPN отвечает на проверки' || doctor_warn 'дополнительный VPN не отвечает на проверки'
    else
        doctor_ok 'дополнительный VPN не настроен'
    fi
    if scheme_running; then
        if rule_is_on; then doctor_ok "ip rule $PRIO ведёт в table $TABLE"
        elif ip rule show | grep -q "^$PRIO:"; then doctor_fail "ip rule $PRIO занято другим сервисом"
        else doctor_warn "основное ip rule $PRIO не установлено"; fi
        if ip rule show | grep -q "^$FORCE_PRIO:.*lookup $FORCE_TABLE"; then doctor_ok "ip rule $FORCE_PRIO ведёт в table $FORCE_TABLE"
        elif ip rule show | grep -q "^$FORCE_PRIO:"; then doctor_fail "ip rule $FORCE_PRIO занято другим сервисом"
        else doctor_warn "ip rule $FORCE_PRIO для ручных списков не установлено"; fi
    else
        doctor_ok 'основная схема выключена'
    fi
    n=$(lines "$RU_LIST")
    [ "$n" -gt 3000 ] && doctor_ok "сетей РФ в списке: $n" || doctor_warn "список сетей РФ отсутствует или подозрительно мал: $n"
    if ai_is_on; then
        ai_ok && doctor_ok "AI-защита активна: $(wc -l < "$AI_RESOLVED") адресов и подсетей" || doctor_fail 'AI-защита включена, но применена не полностью'
    else
        doctor_ok 'AI-защита выключена'
    fi
    if ! devices_validate; then
        doctor_fail 'devices.conf содержит ошибку или дублирующийся IPv4'
    elif device_entries | grep -q .; then
        devices_ok && doctor_ok 'правила устройств совпадают с devices.conf' || doctor_fail 'правила устройств отсутствуют или конфликтуют'
    elif ip rule show | grep -q "^$DEV_PRIO:"; then
        doctor_fail 'присутствуют лишние правила отдельных устройств'
    else
        doctor_ok 'индивидуальных политик устройств нет'
    fi
    if [ -f "$IPV6_BLOCK_FILE" ]; then
        ip6tables -C FORWARD -i "$LAN_IF" -j $IPV6_CHAIN 2>/dev/null && ip6tables -S $IPV6_CHAIN 2>/dev/null | grep -q -- '-j DROP' \
            && doctor_ok 'внешний IPv6 блокируется правилами Razvilka' || doctor_fail 'IPv6-блокировка включена, но правила отсутствуют'
    fi
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        if [ -f "$IPV6_BLOCK_FILE" ]; then doctor_warn 'глобальный IPv6 присутствует: внешний трафик блокируется, IPv6-only ресурсы недоступны'
        else doctor_warn 'обнаружен глобальный IPv6, но блокировка выключена: возможны утечки мимо VPN'; fi
    else
        doctor_ok 'глобальный IPv6 не обнаружен'
    fi
    listeners=$(netstat -ltn 2>/dev/null)
    if printf '%s\n' "$listeners" | grep -E "(0\.0\.0\.0:|:::)${WEB_PORT}[[:space:]]" >/dev/null; then
        doctor_warn "панель слушает все интерфейсы, порт $WEB_PORT"
    elif ! printf '%s\n' "$listeners" | grep -F "$LAN_IP:$WEB_PORT " >/dev/null; then
        doctor_fail "панель не слушает $LAN_IP:$WEB_PORT"
    else
        doctor_ok "панель слушает только $LAN_IP:$WEB_PORT"
    fi
    [ -n "$(resolve chatgpt.com | head -1)" ] && doctor_ok 'DNS разрешает chatgpt.com' || doctor_warn 'DNS не может разрешить chatgpt.com'
    return "$DOCTOR_FAIL"
}

status_kv() {
    echo "enabled=$(scheme_running && echo 1 || echo 0)"
    echo "rule=$(rule_is_on && echo 1 || echo 0)"
    echo "tunnel=$(tunnel_ok && echo 1 || echo 0)"
    echo "kill=$([ -f "$KILL_FLAG" ] && echo 1 || echo 0)"
    echo "killtest=$(killtest_active && echo 1 || echo 0)"
    echo "failmode=$(failmode)"
    echo "fails=$(cat "$FAILS" 2>/dev/null || echo 0)"
    echo "routes=$(table_count $TABLE)"
    echo "ru=$(lines "$RU_LIST")"
    echo "ru_date=$(date -r "$RU_LIST" '+%F %H:%M' 2>/dev/null)"
    echo "vpn_if=$VPN_IF"
    echo "vpn2_if=$VPN2_IF"
    echo "vpn2_tunnel=$([ -n "$VPN2_IF" ] && tunnel_ok "$VPN2_IF" && echo 1 || echo 0)"
    echo "vpn_rx_bytes=$(traffic_bytes "$VPN_IF" | cut -d'|' -f1)"
    echo "vpn_tx_bytes=$(traffic_bytes "$VPN_IF" | cut -d'|' -f2)"
    echo "isp_rx_bytes=$(traffic_bytes "$ISP_IF" | cut -d'|' -f1)"
    echo "isp_tx_bytes=$(traffic_bytes "$ISP_IF" | cut -d'|' -f2)"
    echo "isp_if=$ISP_IF"
    echo "vpn_ip=$(ip -4 addr show $VPN_IF 2>/dev/null | awk '/inet /{print $2; exit}')"
    echo "lan_ip=$LAN_IP"
    echo "stub_port=$STUB_PORT"
    echo "direct_n=$(count_entries "$DIRECT_LIST")"
    echo "allow_n=$(lines "$DIR/allow.resolved")"
    echo "tunnel_since=$(cut -d' ' -f2 "$TUNNEL_STATE" 2>/dev/null)"
    echo "last_check=$(cat "$DIR/last_check" 2>/dev/null)"
    echo "now=$(date +%s)"
    echo "vpn_n=$(count_entries "$VPN_LIST")"
    echo "force_routes=$(table_count $FORCE_TABLE)"
    echo "ai_protect=$(ai_is_on && echo 1 || echo 0)"
    echo "ai_active=$(ai_ok && echo 1 || echo 0)"
    echo "ai_routes=$(lines "$AI_RESOLVED")"
    echo "ai_failed=$(lines "$AI_FAILED")"
    echo "ai_vpn_routes=$(table_routes $AI_TABLE | grep -c "dev $VPN_IF")"
    echo "ai_refreshed=$(cat "$DIR/ai.refreshed" 2>/dev/null)"
    echo "ipv6_blocked=$([ -f "$IPV6_BLOCK_FILE" ] && echo 1 || echo 0)"
    echo "ipv6_present=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)"
    echo "devices_n=$(device_entries | wc -l)"
    echo "device_rules=$(ip rule show | grep -c "^$DEV_PRIO:")"
    echo "devices_active=$(devices_ok && echo 1 || echo 0)"
    echo "$(cat "$STATE" 2>/dev/null)" | tr ' ' '\n'
}

# shellcheck shell=sh
# ---------- подключённые устройства ----------

neighbors() {
    raw=$DIR/neighbors.raw
    : > "$raw"
    ip neigh show 2>/dev/null | awk '$4 ~ /^lladdr$/ {print $1 "|" $5 "||" $6}' >> "$raw"
    if [ ! -s "$raw" ] && [ -r /proc/net/arp ]; then
        awk '$4 ~ /^[0-9a-fA-F:]+$/ {print $1 "|" $4 "||" $6}' /proc/net/arp >> "$raw"
    fi
    if command -v ndmc >/dev/null 2>&1; then
        ndmc -c 'show ip dhcp leases' 2>/dev/null | awk '
            /^(ip|ip-address|address|ip address):/{ip=$2}
            /^(mac|mac-address|mac address):/{mac=$2}
            /^(hostname|host|name):/{name=$2}
            /^[[:space:]]*$/ {if (ip != "") print ip "|" mac "|" name; ip=mac=name=""}
            END {if (ip != "") print ip "|" mac "|" name}
        ' >> "$raw"
    fi
    awk -F'|' -v lan="$LAN_IP" '
        function valid(ip, o,n) {
            n=split(ip,o,".")
            if (n != 4) return 0
            for (n=1;n<=4;n++) if (o[n] < 0 || o[n] > 255) return 0
            if (o[1] == 10) return 1
            if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 1
            if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 1
            if (o[1] == 192 && o[2] == 168) return 1
            return 0
        }
        $1 == lan || !valid($1) { next }
        function valid_mac(m, a,n) {
            if (length(m) != 17 || m !~ /^[0-9a-fA-F:]+$/) return 0
            n=split(m,a,":")
            if (n != 6) return 0
            for (n=1;n<=6;n++) if (length(a[n]) != 2) return 0
            return 1
        }
        !valid_mac($2) { $2="-" }
        { gsub(/[|\r\n]/,"",$3); $3=substr($3,1,80); if (seen[$1]++) next; print $1 "|" $2 "|" $3 "|" $4 }
    ' "$raw" | head -100
    rm -f "$raw"
}
# shellcheck shell=sh
# ---------- резервное копирование и восстановление ----------

TAR_BIN=${TAR_BIN:-/opt/bin/tar}
BACKUP_DIR=$DIR/backups
BACKUP_FILES='razvilka.conf devices.conf failmode contact.txt web.users csrf.token ai_protect ipv6_block enabled kill-allow.presets lists/direct.list lists/vpn.list lists/kill-allow.list'
BACKUP_REQUIRED='razvilka.conf failmode web.users csrf.token lists/direct.list lists/vpn.list'

# Все пути заданы константами пакета. Запись через rename сохраняет прежний файл при ошибке копирования.
settings_copy() (
    from=$1; to=$2
    shift 2
    [ ! -L "$from/lists" ] && [ ! -L "$to/lists" ] && mkdir -p "$to/lists" || exit 1
    for entry in "$@"; do
        src=$from/$entry; dst=$to/$entry
        [ ! -L "$src" ] && [ ! -L "$dst" ] || exit 1
        [ ! -e "$dst" ] || [ -f "$dst" ] || exit 1
        if [ -f "$src" ]; then
            tmp=$(mktemp "$to/.copy.XXXXXX") || exit 1
            if ! cat "$src" > "$tmp" || ! mv -f "$tmp" "$dst"; then rm -f "$tmp"; exit 1; fi
        elif [ -e "$src" ]; then
            exit 1
        else
            rm -f "$dst" || exit 1
        fi
    done
)
settings_manifest() (
    cd "$1" || exit 1
    for entry in $BACKUP_REQUIRED; do [ -f "$entry" ] || exit 1; done
    for entry in $BACKUP_FILES; do
        [ -f "$entry" ] || continue
        checksum=$(sha256sum "$entry") || exit 1
        printf '%s %s\n' "$checksum" "$entry"
    done
)
backup_settings() (
    umask 077
    [ ! -L "$BACKUP_DIR" ] && mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || exit 1
    work=$(mktemp -d "$BACKUP_DIR/.creating.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    settings_copy "$DIR" "$work" $BACKUP_FILES || exit 1
    settings_manifest "$work" > "$work/manifest" || { log 'backup: отсутствуют обязательные настройки'; exit 1; }
    set -- manifest
    for entry in $BACKUP_FILES; do [ ! -f "$work/$entry" ] || set -- "$@" "$entry"; done
    "$TAR_BIN" czf "$work/archive" -C "$work" "$@" || exit 1
    archive_name=backup-$(date +%Y%m%d-%H%M%S)-${work##*.}.tar.gz
    mv "$work/archive" "$BACKUP_DIR/$archive_name" || exit 1
    log "backup: создан $BACKUP_DIR/$archive_name"
    printf '%s\n' "$BACKUP_DIR/$archive_name"
)
restore_unpack() (
    archive=$1; work=$2; target=$work/new
    # Отдельно проверяем результат tar: ошибка чтения не должна скрываться за успешным awk.
    LC_ALL=C "$TAR_BIN" tzf "$archive" > "$work/names" &&
        LC_ALL=C "$TAR_BIN" tvzf "$archive" > "$work/types" || exit 1
    awk -v names="$BACKUP_FILES manifest" '
        BEGIN { n=split(names,a," "); for (i=1;i<=n;i++) allowed[a[i]]=1 }
        $0 != "lists/" && !($0 in allowed) { exit 1 }
        seen[$0]++ { exit 1 }
    ' "$work/names" || exit 1
    awk 'substr($0,1,1) != "-" && !(substr($0,1,1) == "d" && $NF == "lists/") { exit 1 }' "$work/types" || exit 1
    mkdir -p "$target/lists" || exit 1
    while IFS= read -r entry; do
        [ "$entry" != lists/ ] || continue
        # tar отдаёт только содержимое. Владельцы, права и пути из архива не применяются.
        "$TAR_BIN" xOzf "$archive" "$entry" > "$target/$entry" || exit 1
    done < "$work/names"
    settings_manifest "$target" > "$work/check" || exit 1
    [ ! -f "$target/manifest" ] || cmp -s "$target/manifest" "$work/check"
)
restore_validate_conf() {
    # Старые архивы могут содержать произвольную команду перезапуска, уже разрешённую
    # локальным администратором. Из нового архива разрешаем только штатный init restart.
    TRUSTED_RESTART="$VPN_RESTART" awk '
        function ipv4(s, a,i) {
            if (split(s,a,".")!=4) return 0
            for (i=1;i<=4;i++) if (a[i]!~/^[0-9]+$/ || a[i]>255) return 0
            return 1
        }
        /^[[:space:]]*$/ || /^#/ {next}
        {
            pos=index($0,"="); if (!pos) exit 1
            k=substr($0,1,pos-1); v=substr($0,pos+1); q=substr(v,1,1)
            if (seen[k]++) exit 1
            if (q=="\"" || q==sprintf("%c",39)) {
                if (length(v)<2 || substr(v,length(v))!=q) exit 1
                v=substr(v,2,length(v)-2)
                if (index(v,q) || (q=="\"" && v ~ /[$`\\]/)) exit 1
            } else if (v !~ /^[A-Za-z0-9_.:\/@+-]*$/) exit 1
            if (k=="VPN_RESTART") {
                if (v!="" && v!=ENVIRON["TRUSTED_RESTART"] && v !~ /^\/opt\/etc\/init\.d\/S[0-9][0-9][A-Za-z0-9_-]+ restart$/) exit 1
            } else if (k=="LAN_IP" || k=="ALIAS_IP") {
                if (!(k=="ALIAS_IP" && v=="") && (!ipv4(v) || v=="0.0.0.0")) exit 1
            } else if (k=="VPN_SERVERS_EXTRA" || k=="VPN2_SERVERS_EXTRA") {
                n=split(v,a," "); for (i=1;i<=n;i++) if (!ipv4(a[i])) exit 1
            } else if (k=="WEB_PORT" || k=="STUB_PORT") {
                if (v!~/^[0-9]+$/ || v+0<1 || v+0>65535) exit 1
            } else if (k=="CAPTIVE_STUB") {
                if(v!="0" && v!="1") exit 1
            } else if (k ~ /^(LAN_IF|VPN_IF|ISP_IF|VPN2_IF|VPN_PROCESS|VPN2_PROCESS|HOSTNAME_LAN)$/) {
                if (v=="" && k ~ /^(LAN_IF|VPN_IF|ISP_IF)$/) exit 1
                if (v!="" && v!~/^[A-Za-z0-9_][A-Za-z0-9_.+-]*$/) exit 1
            } else exit 1
        }
    ' "$1"
}
restore_validate_settings() (
    target=$1
    [ -s "$target/razvilka.conf" ] && restore_validate_conf "$target/razvilka.conf" || exit 1
    DEVICES_FILE=$target/devices.conf
    devices_validate || exit 1
    awk 'NR != 1 || $0 !~ /^(direct|soft|kill)$/ {bad=1} END{exit (bad || NR!=1)}' "$target/failmode" &&
        awk 'NR != 1 || $0 !~ /^[A-Za-z0-9]+$/ {bad=1} END{exit (bad || NR!=1)}' "$target/csrf.token" &&
        awk '!/^[^:[:space:]]+:.+$/ {bad=1} END{exit (bad || !NR)}' "$target/web.users"
)
restore_web_values() (
    DIR=$1; load_router_config || exit 1
    printf '%s|%s|%s|%s|%s\n' "$LAN_IP" "$WEB_PORT" "$STUB_PORT" "$ALIAS_IP" "$HOSTNAME_LAN"
)
restore_prepare_web() (
    work=$1
    if [ ! -f "$DIR/lighttpd.conf.in" ]; then
        [ "$(restore_web_values "$work/new")" = "$(restore_web_values "$DIR")" ]
        exit $?
    fi
    tmpl=$DIR/lighttpd.conf.in
    DIR=$work/new; load_router_config || exit 1
    if [ -n "$ALIAS_IP" ]; then alias_edit="s/@ALIAS_IP@/$ALIAS_IP/g"; else alias_edit='/^#ALIAS_BEGIN/,/^#ALIAS_END/d'; fi
    sed -e "s/@LAN_IP@/$LAN_IP/g" -e "s/@WEB_PORT@/$WEB_PORT/g" -e "s/@STUB_PORT@/$STUB_PORT/g" -e "$alias_edit" "$tmpl" > "$work/new/lighttpd.conf" || exit 1
    "${RZ_TEST_LIGHTTPD:-/opt/sbin/lighttpd}" -tt -f "$work/new/lighttpd.conf"
)
restore_apply() (
    previous=$1
    IFS='|' read -r prev_lan prev_web prev_stub prev_alias prev_host <<EOF
$(restore_web_values "$previous")
EOF
    old_lan_if=$(DIR=$previous; load_router_config && printf '%s' "$LAN_IF") || exit 1
    load_router_config || exit 1
    rm -f "$DIR/devices.state" || exit 1
    if [ -f "$ENABLED" ]; then
        start_main || exit 1
    elif [ -f "$previous/enabled" ]; then
        stop_main || exit 1
    else
        device_apply || exit 1
    fi
    if ai_is_on; then
        if [ ! -f "$ENABLED" ]; then ai_refresh && ai_apply || exit 1; fi
    elif [ -f "$previous/ai_protect" ]; then ai_off || exit 1; fi
    if [ -f "$previous/ipv6_block" ] && { [ "$old_lan_if" != "$LAN_IF" ] || [ ! -f "$IPV6_BLOCK_FILE" ]; }; then
        ( LAN_IF=$old_lan_if; ipv6_block_off ) || exit 1
    fi
    ipv6_block_on && make_stub || exit 1
    if [ "$prev_alias" != "$ALIAS_IP" ] && [ -n "$prev_alias" ]; then
        if ip -4 addr show br0 | grep -Fq " $prev_alias/"; then ip addr del "$prev_alias/32" dev br0 || exit 1; fi
    fi
    if [ -n "$ALIAS_IP" ] && ! ip -4 addr show br0 | grep -Fq " $ALIAS_IP/"; then
        ip addr add "$ALIAS_IP/32" dev br0 || exit 1
    fi
    if [ "$prev_alias|$prev_host" != "$ALIAS_IP|$HOSTNAME_LAN" ]; then
        if [ -n "$prev_alias" ] && [ -n "$prev_host" ]; then
            for host in "$prev_host" "${prev_host%.*}.local"; do ndmc -c "no ip host $host $prev_alias" || exit 1; done
        fi
        if [ -n "$ALIAS_IP" ] && [ -n "$HOSTNAME_LAN" ]; then
            for host in "$HOSTNAME_LAN" "${HOSTNAME_LAN%.*}.local"; do ndmc -c "ip host $host $ALIAS_IP" || exit 1; done
        fi
        ndmc -c 'system configuration save' || exit 1
    fi
    if [ -f "$DIR/lighttpd.conf" ] && { ! cmp -s "$previous/lighttpd.conf" "$DIR/lighttpd.conf" || ! cmp -s "$previous/web.users" "$DIR/web.users"; }; then
        # Фоновый lighttpd не должен наследовать дескриптор блокировки вызывающего CLI.
        LOCK_HELD=1 "${RZ_TEST_WEB_INIT:-/opt/etc/init.d/S81razvilka-web}" restart 9>&- || exit 1
    fi
    flush_flows
)
restore_settings() (
    umask 077
    [ -f "$1" ] && [ ! -L "$1" ] || { echo 'restore: архив не найден или является симлинком' >&2; exit 1; }
    work=$(mktemp -d "$DIR/.restore.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    cp "$1" "$work/archive" && restore_unpack "$work/archive" "$work" &&
        restore_validate_settings "$work/new" && restore_prepare_web "$work" || {
        echo 'restore: архив неполон или содержит недопустимые настройки' >&2; exit 1
    }
    restore_files=$BACKUP_FILES
    [ ! -f "$work/new/lighttpd.conf" ] || restore_files="$restore_files lighttpd.conf"
    settings_copy "$DIR" "$work/old" $restore_files || exit 1
    # Старый конфиг веб-сервера нужен и для сравнения при обновлении со старой версии.
    if [ -f "$DIR/lighttpd.conf" ] && [ ! -f "$work/old/lighttpd.conf" ]; then
        cp "$DIR/lighttpd.conf" "$work/old/lighttpd.conf" || exit 1
    fi
    restore_finish() {
        result=$?
        trap - EXIT HUP INT TERM
        if [ "$result" != 0 ]; then
            if ! settings_copy "$work/old" "$DIR" $restore_files || ! restore_apply "$work/new"; then
                echo "restore: откат не завершён; исходные файлы сохранены в $work/old" >&2
                log "backup: ошибка отката, исходные файлы в $work/old"
                exit 1
            fi
            log 'backup: прежние настройки возвращены'
        fi
        rm -rf "$work"
        exit "$result"
    }
    trap 'restore_finish' EXIT
    settings_copy "$work/new" "$DIR" $restore_files && restore_apply "$work/old" || exit 1
    log 'backup: настройки восстановлены'
)
# shellcheck shell=sh
start_main() {
    start_rc=0
    mkdir -p "$DIR" "$LISTS" "$(dirname "$LOG")" || return 1
    rm -f "$DIR/.service-stopped"
    touch "$ENABLED" || return 1
    echo 0 > "$FAILS"
    legacy_kill_off
    guard_on || return 1
    if [ "$(failmode)" != direct ] && ! rule_is_on; then kill_on || return 1; fi
    ipv6_block_on || start_rc=1
    [ -f "$DIR/stub/index.html" ] || make_stub || start_rc=1
    build_force || start_rc=1
    device_apply || start_rc=1
    ai_refresh || start_rc=1; ai_apply || start_rc=1
    if tunnel_ok; then
        if [ -f "$KILL_FLAG" ]; then kill_off || return 1
        else build || return 1; rule_on || return 1; fi
        build_allow || start_rc=1
        log "включено"
    elif [ "$(failmode)" != direct ]; then
        kill_on || return 1
    else
        kill_off direct || return 1
        rule_off || return 1
        log "включено, жду туннель (сторож достроит)"
    fi
    return "$start_rc"
}
stop_main() {
    stop_rc=0
    [ "${1:-}" = service ] || rm -f "$ENABLED"
    rm -f "$TEST_UNTIL"
    kill_off stop || stop_rc=1
    legacy_kill_off
    rule_off || stop_rc=1
    guard_off || stop_rc=1
    flush_table "$TABLE" || stop_rc=1
    force_off || stop_rc=1
    ipv6_block_on || stop_rc=1
    device_apply || stop_rc=1
    ai_apply || stop_rc=1
    log "основная схема выключена; политики устройств и AI-защита сохраняют своё состояние"
    return "$stop_rc"
}

case "$1" in
    status|status-kv|lookup|why|presets|doctor|neighbors|netfilter|'') ;;
    *) lock_acquire || exit $? ;;
esac

case "$1" in
    neighbors)
        neighbors
        ;;
    backup)
        backup_settings
        ;;
    restore)
        restore_settings "$2"
        ;;
    ipv6-block)
        case "$2" in
            on) touch "$IPV6_BLOCK_FILE"; ipv6_block_on && log 'внешний IPv6 заблокирован' ;;
            off) rm -f "$IPV6_BLOCK_FILE"; ipv6_block_off && log 'внешний IPv6 разрешён' ;;
            *) echo "usage: $0 ipv6-block on|off"; exit 1 ;;
        esac
        ;;
    device-set)
        device_set "$2" "$3" "${4:-}" "${5:-}" "${6:-}"
        ;;
    device-del)
        device_del "$2"
        ;;
    device-apply)
        device_apply
        ;;
    device-clear-rules)
        device_clear
        ;;
    ai-on)
        mkdir -p "$DIR" "$LISTS" "$(dirname "$LOG")"; touch "$AI_ENABLED"
        ai_refresh
        if ai_apply; then flush_flows; log 'AI-защита включена: Claude Code и ChatGPT не пойдут напрямую'; else exit 1; fi
        ;;
    ai-off)
        rm -f "$AI_ENABLED"; ai_off || exit 1; flush_flows; log 'AI-защита выключена'
        ;;
    ai-refresh)
        ai_refresh || exit 1; ai_apply
        ;;
    ai-apply)
        ai_apply
        ;;
    service-start)
        rm -f "$DIR/.service-stopped"
        if [ -f "$ENABLED" ]; then start_main; else watchdog; fi
        ;;
    service-stop)
        touch "$DIR/.service-stopped" && stop_main service
        ;;
    start)
        start_main
        ;;
    stop)
        stop_main
        ;;
    update)
        download || exit 1
        if scheme_running; then
            if [ -f "$KILL_FLAG" ]; then kill_on || exit 1
            elif tunnel_ok; then build && rule_on || exit 1
            elif [ "$(failmode)" != direct ]; then kill_on || exit 1; fi
        fi
        device_apply || exit 1
        ;;
    lists)
        rc=0
        [ "${2:-}" = refresh ] && ASN_REFRESH=1
        if scheme_running; then build_force || rc=1
        elif device_entries | grep -Fq '|vpn-list|'; then refresh_vpn_list || rc=1; fi
        if tunnel_ok; then build_allow || rc=1; fi
        device_apply || rc=1
        ai_refresh || rc=1; ai_apply || rc=1
        [ "$rc" = 0 ]
        ;;
    why)
        why "$2"
        ;;
    lookup)
        lookup "$2" "${3:-}" "${4:-}"
        ;;
    alias-on)
        alias_on
        ;;
    alias-off)
        alias_off
        ;;
    presets)
        on=" $(presets_on | tr '\n' ' ') "
        presets | while IFS='|' read -r k n e; do case "$on" in *" $k "*) c=1 ;; *) c=0 ;; esac; echo "$k|$c|$n|$e"; done
        ;;
    allow)
        build_allow || exit 1; echo "разрешено при падении туннеля: $(wc -l < "$DIR/allow.resolved") адресов/подсетей"
        ;;
    watchdog)
        watchdog
        ;;
    mode)
        case "$2" in
            kill|soft|direct)
                echo "$2" > "$MODE_FILE"; log "режим при падении VPN: $2"; watchdog ;;
            *) echo "usage: $0 mode direct|soft|kill"; exit 1 ;;
        esac
        ;;
    killtest)
        if [ "$2" = off ]; then
            if ! scheme_running; then stop_main service || exit 1
            else rm -f "$TEST_UNTIL"; watchdog || exit 1; fi
            log "тест kill switch остановлен"
        else
            scheme_running || { log "для теста kill switch включите основную схему"; exit 1; }
            min=${2:-3}; case "$min" in ''|*[!0-9]*) min=3 ;; esac; [ "$min" -gt 30 ] && min=30
            echo $(( $(date +%s) + min * 60 )) > "$TEST_UNTIL"
            log "тест kill switch на $min мин"
            kill_on
        fi
        ;;
    stub)
        make_stub
        ;;
    netfilter)
        :   # хук netfilter.d больше не используется (см. блок kill switch)
        ;;
    vpn-restart)
        [ -n "$VPN_RESTART" ] || { log "VPN_RESTART не задан в razvilka.conf"; exit 1; }
        log "перезапуск VPN: $VPN_RESTART"
        sh -c "$VPN_RESTART" </dev/null >/dev/null 2>&1 || exit 1; sleep 5; watchdog
        ;;
    doctor)
        doctor
        ;;
    status-kv)
        status_kv
        ;;
    status)
        status_kv
        tail -n 8 "$LOG" 2>/dev/null
        ;;
    *)
        echo "usage: $0 start|stop|update|lists [refresh]|ai-on|ai-off|ai-refresh|ai-apply|backup|restore FILE|neighbors|ipv6-block on\|off|device-set IP default\|direct\|vpn\|vpn-all\|vpn-list [primary\|secondary] [NAME]|device-del IP|device-apply|doctor|why IP|watchdog|mode direct|soft|kill|killtest N|off|stub|netfilter|vpn-restart|status"; exit 1
        ;;
esac
