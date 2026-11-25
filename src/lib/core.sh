#!/bin/sh
# Razvilka — весь иностранный трафик через VPN, российский напрямую, с kill switch.
# Ставится инсталлятором (razvilka-setup.sh), настройки — /opt/razvilka/razvilka.conf.
#
# Порядок правил маршрутизации (первое совпадение выигрывает):
#   30016 -> table 1030–1036   индивидуальные политики: direct, primary/secondary VPN, fail-closed
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
DEV_LEGACY_TABLES="1032 1035"
DEV_TABLES="$DEV_DIRECT_TABLE $DEV_VPN_TABLE $DEV_VPN2_TABLE $DEV_ALL_TABLE $DEV_ALL2_TABLE $DEV_LEGACY_TABLES"
SET=razvilka_direct          # ipset для правила заглушки (см. блок kill switch)
LISTS=$DIR/lists
DIRECT_LIST=$LISTS/direct.list
VPN_LIST=$LISTS/vpn.list
RU_LIST=$DIR/ru.cidr
ASN_DIR=$DIR/asn           # кэш подсетей автономных систем (AS13238.cidr)
ASN_TTL=86400              # обновлять раз в сутки
ASN_API="https://stat.ripe.net/data/announced-prefixes/data.json?resource="
ENABLED=$DIR/enabled
STATE=$DIR/state          # gw и vpn-сервер, с которыми строилась таблица
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
PRIVATE="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"

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

isp_gw() {
    ip route show table main default | awk -v d="$ISP_IF" '$0 ~ "dev " d {for (i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}'
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
    gw=$(isp_gw)
    servers=$(vpn_servers)
    if [ "$down" != down ]; then
        [ -n "$gw" ] || { log "нет шлюза провайдера на $ISP_IF"; return 1; }
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
        if [ -n "$gw" ]; then
            for s in $servers; do echo "route replace $s/32 via $gw dev $ISP_IF table $TABLE"; done
            [ ! -s "$RU_LIST" ] || awk -v gw="$gw" -v d="$ISP_IF" -v t="$TABLE" '{print "route replace " $1 " via " gw " dev " d " table " t}' "$RU_LIST"
        fi
        [ "$down" = down ] || echo "route replace default dev $VPN_IF metric 10 table $TABLE"
    } > "$DIR/batch"
    reconcile_routes "$DIR/batch" "$TABLE" 'основная таблица: ошибка ip -batch' || return 1
    flush_cache
    echo "gw=$gw servers=$(echo $servers)" > "$STATE"
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

