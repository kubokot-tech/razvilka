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
