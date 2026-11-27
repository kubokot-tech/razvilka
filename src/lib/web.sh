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

