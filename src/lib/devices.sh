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
