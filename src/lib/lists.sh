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

