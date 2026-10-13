#!/bin/sh
# Razvilka — весь иностранный трафик через VPN, российский напрямую, с kill switch.
# Ставится инсталлятором (razvilka-setup.sh), настройки — /opt/razvilka/razvilka.conf.
#
# Порядок правил маршрутизации (первое совпадение выигрывает):
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
#   razvilka.sh start | stop          включить / выключить (stop — всё как без пакета)
#   razvilka.sh update                перекачать список сетей РФ и перестроить
#   razvilka.sh lists                 перечитать ручные списки (домены -> IP, AS -> подсети), раз в час
#   razvilka.sh lists refresh         то же, но подсети AS скачать заново (не ждать суток)
#   razvilka.sh why IP                из какой записи ручного списка взялся адрес
#   razvilka.sh lookup IP             всё про адрес: маршрут, списки, РФ ли, чья AS (для веб-морды)
#   razvilka.sh watchdog              раз в минуту из cron
#   razvilka.sh mode kill|direct
#   razvilka.sh killtest N | off      показать заглушку N минут при живом VPN (проверка)
#   razvilka.sh stub                  пересобрать страницу-заглушку (после смены контакта)
#   razvilka.sh netfilter             переприменить правила iptables (хук ndm/netfilter.d)
#   razvilka.sh vpn-restart           перезапустить VPN (команда VPN_RESTART из razvilka.conf)
#   razvilka.sh status | status-kv

export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root

DIR=/opt/razvilka

# --- настройки по умолчанию; переопределяются в razvilka.conf (пишет инсталлятор) ---
VPN_IF=opkgtun0
ISP_IF=eth3
LAN_IF='br+'             # все бриджи: домашняя и гостевая сети
LAN_IP=192.168.1.1
STUB_PORT=8098
WEB_PORT=98
VPN_SERVERS_EXTRA=""     # адреса VPN-сервера вручную, если не определяются сами
VPN_PROCESS=""           # имя процесса VPN-клиента: по его соединениям находится адрес сервера
VPN_RESTART=""           # команда перезапуска VPN для кнопки в веб-морде
[ -f "$DIR/razvilka.conf" ] && . "$DIR/razvilka.conf"

TABLE=1022
PRIO=30022
FORCE_TABLE=1020
FORCE_PRIO=30020
SET=razvilka_direct          # ipset: куда можно напрямую, когда VPN упал
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
}

failmode() { m=$(cat "$MODE_FILE" 2>/dev/null); [ "$m" = direct ] && echo direct || echo kill; }

isp_gw() {
    ip route show table main default | awk -v d="$ISP_IF" '$0 ~ "dev " d {for (i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}'
}

# dig, а не nslookup: busybox nslookup дописывает после IP имя из PTR-записи
resolve() { dig +short +time=3 +tries=1 "$1" A 2>/dev/null | grep -E "$IPV4" | grep -v '^127\.'; }

# Адреса VPN-сервера — должны идти напрямую, иначе петля. Источники:
# соединения процесса VPN-клиента (VPN_PROCESS), endpoints AmneziaWG/WireGuard, VPN_SERVERS_EXTRA.
# Последние найденные запоминаются: когда VPN лежит, соединения нет, а адрес всё равно нужен.
vpn_servers() {
    live=$({
        [ -n "$VPN_PROCESS" ] && netstat -tunp 2>/dev/null | awk -v p="/$VPN_PROCESS" 'index($NF, p) == 1 || index($NF, p) > 0 {split($5, a, ":"); print a[1]}'
        for t in awg wg; do
            command -v $t >/dev/null 2>&1 && $t show "$VPN_IF" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1
        done
    } | grep -E "$IPV4" | grep -vE '^(0\.|127\.|10\.|192\.168\.)' | sort -u)
    [ -n "$live" ] && echo "$live" > "$DIR/servers.last"
    { [ -n "$live" ] && echo "$live" || cat "$DIR/servers.last" 2>/dev/null
      for s in $VPN_SERVERS_EXTRA; do echo "$s"; done
    } | grep -E "$IPV4" | sort -u
}

tunnel_ok() {
    ip link show "$VPN_IF" >/dev/null 2>&1 || return 1
    ping -I "$VPN_IF" -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -I "$VPN_IF" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1
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
    gw=$(isp_gw)
    [ -z "$gw" ] && { log "нет шлюза провайдера на $ISP_IF, таблицу не строю"; return 1; }
    ip link show "$VPN_IF" >/dev/null 2>&1 || { log "нет интерфейса $VPN_IF, таблицу не строю"; return 1; }
    [ -s "$RU_LIST" ] || download || { log "нет списка РФ, таблицу не строю"; return 1; }
    servers=$(vpn_servers)
    [ -z "$servers" ] && { log "не нашёл адрес VPN-сервера — без исключения будет петля, таблицу не строю (задайте VPN_SERVERS_EXTRA в razvilka.conf)"; return 1; }

    {
        echo "route flush table $TABLE"
        for p in $PRIVATE; do echo "route add throw $p table $TABLE"; done
        for s in $servers; do echo "route add $s/32 via $gw dev $ISP_IF table $TABLE"; done
        awk -v gw="$gw" -v d="$ISP_IF" -v t="$TABLE" '{print "route replace " $1 " via " gw " dev " d " table " t}' "$RU_LIST"
        echo "route add default dev $VPN_IF table $TABLE"
    } > "$DIR/batch"
    if ip -batch "$DIR/batch" 2>"$DIR/batch.err"; then
        flush_cache
        echo "gw=$gw servers=$(echo $servers)" > "$STATE"
        log "таблица $TABLE: $(wc -l < "$RU_LIST") сетей РФ напрямую через $gw, vpn-сервер(ы) $(echo $servers) напрямую, остальное -> $VPN_IF"
        return 0
    fi
    log "ошибка ip -batch: $(head -3 "$DIR/batch.err" | tr '\n' ' ')"
    ip route flush table $TABLE 2>/dev/null
    return 1
}

# у ядра Keenetic есть кэш маршрутов: после любой перестройки его надо сбрасывать,
# иначе старые решения живут ещё какое-то время
flush_cache() { ip route flush cache 2>/dev/null; }
rule_on()  { ip rule show | grep -q "^$PRIO:" || { ip rule add table $TABLE priority $PRIO; flush_cache; }; }
rule_off() { while ip rule show | grep -q "^$PRIO:"; do ip rule del priority $PRIO; done; flush_cache; }
rule_is_on() { ip rule show | grep -q "^$PRIO:"; }
table_ok() { ip route show table $TABLE | grep -q "^default dev $VPN_IF"; }

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

build_force() {
    gw=$(isp_gw)
    [ -z "$gw" ] && { log "списки: нет шлюза провайдера на $ISP_IF"; return 1; }
    list_map "$DIRECT_LIST" > "$DIR/direct.map"
    list_map "$VPN_LIST" > "$DIR/vpn.map"
    awk '{print $1}' "$DIR/direct.map" | sort -u > "$DIR/direct.resolved"
    awk '{print $1}' "$DIR/vpn.map" | sort -u > "$DIR/vpn.resolved"
    {
        echo "route flush table $FORCE_TABLE"
        awk -v gw="$gw" -v d="$ISP_IF" -v t="$FORCE_TABLE" '{print "route replace " $1 " via " gw " dev " d " table " t}' "$DIR/direct.resolved"
        if ip link show "$VPN_IF" >/dev/null 2>&1; then
            # vpn-записи, совпавшие с «напрямую», не дублируем — «напрямую» важнее
            grep -vxF -f "$DIR/direct.resolved" "$DIR/vpn.resolved" | awk -v d="$VPN_IF" -v t="$FORCE_TABLE" '{print "route replace " $1 " dev " d " table " t}'
        fi
    } > "$DIR/force.batch"
    ip -batch "$DIR/force.batch" 2>"$DIR/force.err" || log "списки: ошибки ip -batch: $(head -3 "$DIR/force.err" | tr '\n' ' ')"
    n=$(ip route show table $FORCE_TABLE | wc -l)
    echo "$n" > "$FORCE_STATE"
    ip rule show | grep -q "^$FORCE_PRIO:" || ip rule add table $FORCE_TABLE priority $FORCE_PRIO
    flush_cache
    log "ручные списки: $(wc -l < "$DIR/direct.resolved") адресов напрямую, $(wc -l < "$DIR/vpn.resolved") через VPN (маршрутов $n)"
    [ -f "$KILL_FLAG" ] && build_set
    return 0
}
# маршруты списков пропадают, когда VPN-интерфейс пересоздаётся
force_ok() {
    ip rule show | grep -q "^$FORCE_PRIO:" || return 1
    want=$(cat "$FORCE_STATE" 2>/dev/null || echo 0)
    [ "$(ip route show table $FORCE_TABLE | wc -l)" -ge "$want" ]
}
force_off() {
    while ip rule show | grep -q "^$FORCE_PRIO:"; do ip rule del priority $FORCE_PRIO; done
    ip route flush table $FORCE_TABLE 2>/dev/null
    flush_cache
}

# ---------- kill switch ----------

# ipset «можно напрямую»: РФ + список «напрямую» + VPN-сервер + DNS + локальное
build_set() {
    {
        echo "create ${SET}_tmp hash:net maxelem 131072 -exist"
        echo "flush ${SET}_tmp"
        for p in $PRIVATE; do echo "add ${SET}_tmp $p -exist"; done
        for r in $RESOLVERS; do echo "add ${SET}_tmp $r -exist"; done
        for s in $(vpn_servers); do echo "add ${SET}_tmp $s -exist"; done
        awk '{print "add '"${SET}"'_tmp " $1 " -exist"}' "$RU_LIST"
        [ -f "$DIR/direct.resolved" ] && awk '{print "add '"${SET}"'_tmp " $1 " -exist"}' "$DIR/direct.resolved"
    } > "$DIR/ipset.restore"
    ipset create $SET hash:net maxelem 131072 -exist
    ipset restore < "$DIR/ipset.restore" && ipset swap ${SET}_tmp $SET && ipset destroy ${SET}_tmp
}

# правила iptables (идемпотентно: -C проверяет, есть ли уже)
ipt() { iptables -t "$1" -C $2 2>/dev/null || iptables -t "$1" -I $2; }
ipt_del() { while iptables -t "$1" -C $2 2>/dev/null; do iptables -t "$1" -D $2; done; }
R_STUB="PREROUTING -i $LAN_IF -p tcp --dport 80 -m set ! --match-set $SET dst -j DNAT --to-destination $LAN_IP:$STUB_PORT"
R_TCP="FORWARD -i $LAN_IF -p tcp -m set ! --match-set $SET dst -j REJECT --reject-with tcp-reset"
R_ANY="FORWARD -i $LAN_IF -m set ! --match-set $SET dst -j REJECT --reject-with icmp-net-unreachable"

kill_rules_on() {
    ipt nat "$R_STUB"
    ipt filter "$R_ANY"
    ipt filter "$R_TCP"     # вставляется выше R_ANY: TCP получает мгновенный сброс
}
kill_rules_off() { ipt_del nat "$R_STUB"; ipt_del filter "$R_TCP"; ipt_del filter "$R_ANY"; }

kill_on() {
    build_set || { log "kill switch: не удалось собрать ipset — отпускаю напрямую"; return 1; }
    # трафик самого роутера (DNS, переподключение VPN) — напрямую;
    # устройствам зарубежное режут правила iptables
    gw=$(isp_gw); [ -n "$gw" ] && ip route replace default via "$gw" dev $ISP_IF table $TABLE
    rule_on; flush_cache
    kill_rules_on
    [ -f "$KILL_FLAG" ] || { touch "$KILL_FLAG"; log "KILL SWITCH ВКЛ: зарубежное с устройств закрыто, HTTP -> заглушка"; }
}
kill_off() {
    kill_rules_off
    if [ -f "$KILL_FLAG" ]; then
        rm -f "$KILL_FLAG"
        ip route replace default dev $VPN_IF table $TABLE 2>/dev/null
        flush_cache
        log "kill switch выкл"
    fi
}
killtest_active() { [ -f "$TEST_UNTIL" ] && [ "$(date +%s)" -lt "$(cat "$TEST_UNTIL")" ]; }

# ---------- страница-заглушка ----------

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

make_stub() {
    mkdir -p "$DIR/stub"
    c=$(cat "$CONTACT" 2>/dev/null | html_escape | sed 's/$/<br>/')
    [ -z "$c" ] && c="Позвоните или напишите тому, кто настраивал интернет."
    cat > "$DIR/stub/index.html" <<EOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Зарубежные сайты временно не открываются</title>
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
<h1>Зарубежные сайты сейчас не открываются</h1>
<p class="lead">Это временно. <b>У вас ничего не сломалось.</b></p>
<p class="soft">YouTube, Google, Instagram и другие зарубежные сайты и приложения ненадолго недоступны.</p>

<div class="box ok">
<h2><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M7.5 12.5l3 3 6-6"/></svg>Всё российское работает как обычно</h2>
<ul class="chips"><li>Кинопоиск</li><li>KION</li><li>Яндекс</li><li>ВКонтакте</li><li>Госуслуги</li><li>Банки</li></ul>
</div>

<div class="box calm">
<p><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9"/><path d="M12 7v5l3 2"/></svg><b>Перезагружать ничего не нужно</b> — ни роутер, ни телефон, ни телевизор. Когда связь вернётся, всё заработает само.</p>
</div>

<div class="box help">
<h2><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8l-4 3v-3H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z"/></svg>Если через час не заработало — напишите</h2>
<div class="who">$c</div>
</div>

<small>Эту страницу показывает домашний роутер</small>
</div></main></body></html>
EOF
}

# ---------- сторож ----------

watchdog() {
    [ -f "$ENABLED" ] || return 0
    force_ok || build_force
    if killtest_active; then
        kill_on; return 0
    fi
    rm -f "$TEST_UNTIL"
    if tunnel_ok; then
        echo 0 > "$FAILS"
        [ -f "$KILL_FLAG" ] && { kill_off; log "туннель жив — kill switch снят"; }
        kill_rules_off   # на всякий случай: хук netfilter мог вернуть правила
        # таблица пропала (переподключение VPN удаляет маршруты через dev),
        # сменился шлюз провайдера или адрес VPN-сервера -> перестроить
        want="gw=$(isp_gw) servers=$(echo $(vpn_servers))"
        if ! table_ok || [ "$want" != "$(cat "$STATE" 2>/dev/null)" ]; then
            build || return 1
            build_force
        fi
        if ! rule_is_on; then
            rule_on; log "туннель жив — иностранный трафик снова через VPN"
        fi
    else
        f=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )); echo $f > "$FAILS"
        [ "$f" -ge 2 ] || return 0      # две неудачи подряд (~2 мин)
        if [ "$(failmode)" = kill ]; then
            [ -f "$KILL_FLAG" ] || log "туннель не отвечает ($f проверки)"
            kill_on   # повторяем каждую минуту: правила могли слететь
        else
            kill_off
            if rule_is_on; then
                rule_off; log "туннель не отвечает ($f проверки) — иностранный трафик временно напрямую"
            fi
        fi
    fi
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
    ip route flush cache 2>/dev/null
    r=$(ip route get "$1" 2>/dev/null | head -1)
    dev=$(echo "$r" | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    tbl=$(echo "$r" | awk '{for(i=1;i<NF;i++) if($i=="table"){print $(i+1); exit}}')
    echo "dev=$dev"; echo "table=$tbl"
    for l in direct vpn; do cidr_match "$1" "$DIR/$l.map" all | sort -u | sed "s/^/match_$l=/"; done
    [ -n "$(cidr_match "$1" "$RU_LIST")" ] && echo "ru=1" || echo "ru=0"
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

status_kv() {
    echo "enabled=$([ -f "$ENABLED" ] && echo 1 || echo 0)"
    echo "rule=$(rule_is_on && echo 1 || echo 0)"
    echo "tunnel=$(tunnel_ok && echo 1 || echo 0)"
    echo "kill=$([ -f "$KILL_FLAG" ] && echo 1 || echo 0)"
    echo "killtest=$(killtest_active && echo 1 || echo 0)"
    echo "failmode=$(failmode)"
    echo "fails=$(cat "$FAILS" 2>/dev/null || echo 0)"
    echo "routes=$(ip route show table $TABLE | wc -l)"
    echo "ru=$(wc -l < "$RU_LIST" 2>/dev/null || echo 0)"
    echo "ru_date=$(date -r "$RU_LIST" '+%F %H:%M' 2>/dev/null)"
    echo "vpn_if=$VPN_IF"
    echo "isp_if=$ISP_IF"
    echo "vpn_ip=$(ip -4 addr show $VPN_IF 2>/dev/null | awk '/inet /{print $2; exit}')"
    echo "lan_ip=$LAN_IP"
    echo "stub_port=$STUB_PORT"
    echo "direct_n=$(count_entries "$DIRECT_LIST")"
    echo "vpn_n=$(count_entries "$VPN_LIST")"
    echo "force_routes=$(ip route show table $FORCE_TABLE | wc -l)"
    echo "$(cat "$STATE" 2>/dev/null)" | tr ' ' '\n'
}

case "$1" in
    start)
        mkdir -p "$DIR" "$LISTS" "$(dirname "$LOG")"; touch "$ENABLED"; echo 0 > "$FAILS"
        [ -f "$DIR/stub/index.html" ] || make_stub
        build_force
        if tunnel_ok && build; then rule_on; kill_off; log "включено"; else log "включено, жду туннель (сторож достроит)"; fi
        ;;
    stop)
        rm -f "$ENABLED" "$TEST_UNTIL"; kill_off; kill_rules_off; rule_off
        ip route flush table $TABLE 2>/dev/null; force_off
        ipset destroy $SET 2>/dev/null
        log "выключено"
        ;;
    update)
        download && [ -f "$ENABLED" ] && build && { tunnel_ok && rule_on; }
        [ -f "$KILL_FLAG" ] && kill_on
        ;;
    lists)
        [ "${2:-}" = refresh ] && ASN_REFRESH=1
        [ -f "$ENABLED" ] && build_force
        ;;
    why)
        why "$2"
        ;;
    lookup)
        lookup "$2"
        ;;
    watchdog)
        watchdog
        ;;
    mode)
        case "$2" in
            kill|direct) echo "$2" > "$MODE_FILE"; log "режим при падении VPN: $2"; watchdog ;;
            *) echo "usage: $0 mode kill|direct"; exit 1 ;;
        esac
        ;;
    killtest)
        if [ "$2" = off ]; then
            rm -f "$TEST_UNTIL"; log "тест заглушки остановлен"; watchdog
        else
            min=${2:-3}; case "$min" in ''|*[!0-9]*) min=3 ;; esac; [ "$min" -gt 30 ] && min=30
            echo $(( $(date +%s) + min * 60 )) > "$TEST_UNTIL"
            log "тест заглушки на $min мин"
            kill_on
        fi
        ;;
    stub)
        make_stub
        ;;
    netfilter)
        [ -f "$KILL_FLAG" ] && kill_rules_on
        ;;
    vpn-restart)
        [ -n "$VPN_RESTART" ] || { log "VPN_RESTART не задан в razvilka.conf"; exit 1; }
        log "перезапуск VPN: $VPN_RESTART"
        sh -c "$VPN_RESTART" </dev/null >/dev/null 2>&1; sleep 5; watchdog
        ;;
    status-kv)
        status_kv
        ;;
    status)
        status_kv
        tail -n 8 "$LOG" 2>/dev/null
        ;;
    *)
        echo "usage: $0 start|stop|update|lists [refresh]|why IP|watchdog|mode kill|direct|killtest N|off|stub|netfilter|vpn-restart|status"; exit 1
        ;;
esac
