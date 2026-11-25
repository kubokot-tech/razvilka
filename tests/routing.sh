#!/bin/bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(mktemp -d "$ROOT/.test-tmp-routing.XXXXXX") || exit 1
trap 'rm -rf "$BASE"' EXIT
trap 'exit 1' INT TERM
FAILURES=0
DIG_IP=203.0.113.10

setup_router() {
    T=$BASE/$1
    mkdir -p "$T/lists"
    sed -e "s|^DIR=/opt/razvilka$|DIR=$T|" -e "s|^LOG=/opt/var/log/razvilka.log$|LOG=$T/razvilka.log|" "$ROOT/src/razvilka.sh" > "$T/razvilka.sh"
    : > "$T/rules"; : > "$T/routes1022"; : > "$T/routes1020"; : > "$T/routes1019"; for n in 1030 1031 1032 1033 1034 1035 1036; do : > "$T/routes$n"; done
    echo kill > "$T/failmode"
    echo '81.0.0.0/8' > "$T/ru.cidr"
    echo 'VPN_SERVERS_EXTRA="198.51.100.1"' > "$T/razvilka.conf"
}

mock_batch() {
    local batch=$1 fail_after=0
    if [ -f "$T/fail-batch" ] && [ "$(cat "$T/fail-batch")" = "$(basename "$batch")" ]; then
        [ -s "$T/fail-after" ] || return 1
        fail_after=$(cat "$T/fail-after")
    fi
    awk -v root="$T" -v fail_after="$fail_after" -f "$ROOT/tests/mock-routes.awk" "$batch"
}

ip() {
    local n p src
    [ -f "$T/fail-rule-add" ] && [ "$1 $2" = 'rule add' ] && [ "$(cat "$T/fail-rule-add")" = "$*" ] && return 1
    case "$*" in
        "rule show") cat "$T/rules" ;;
        "route show table main default") echo 'default via 192.0.2.1 dev eth3' ;;
        "neigh show") echo '192.168.1.70 dev br0 lladdr aa:bb:cc:dd:ee:01 REACHABLE' ;;
        "link show opkgtun0") [ -f "$T/vpn-present" ] ;;
        "link show nwg1") [ -f "$T/vpn2-present" ] ;;
        "-6 addr show scope global") return 1 ;;
        "route show table "*) n=$4; cat "$T/routes$n" ;;
        "route flush cache") return 0 ;;
        "-batch "*) mock_batch "$2" ;;
        "rule add from "*)
            echo "$8: from $4 lookup $6" >> "$T/rules"
            ;;
        "rule del from "*)
            src=$4; n=$6; awk -v src="$src" -v n="$n" '!($3 == src && $5 == n)' "$T/rules" > "$T/rules.new"; mv "$T/rules.new" "$T/rules"
            ;;
        "rule add table "*)
            echo "$6: from all lookup $4" >> "$T/rules"
            ;;
        "rule add iif lo table main priority "*)
            echo "$8: from all iif lo lookup main" >> "$T/rules"
            ;;
        "rule add to "*)
            echo "$8: from all to $4 lookup main" >> "$T/rules"
            ;;
        "rule del table "*)
            n=$4; p=$6; awk -v p="$p" -v n="$n" 'index($0,p":")!=1 || $NF != n' "$T/rules" > "$T/rules.new"; mv "$T/rules.new" "$T/rules"
            ;;
        "rule del to "*)
            p=$4; awk -v p="$p" 'index($0," to "p" ")==0' "$T/rules" > "$T/rules.new"; mv "$T/rules.new" "$T/rules"
            ;;
        "rule del iif lo "*)
            awk '!/iif lo/' "$T/rules" > "$T/rules.new"; mv "$T/rules.new" "$T/rules"
            ;;
        "rule del priority "*)
            p=$4; awk -v p="$p" 'index($0,p":")!=1' "$T/rules" > "$T/rules.new"; mv "$T/rules.new" "$T/rules"
            ;;
        "route flush table "*|"route del "*|"route replace "*)
            echo "$*" | awk -v root="$T" -f "$ROOT/tests/mock-routes.awk"
            ;;
        *) return 0 ;;
    esac
}
ping() { case "$*" in *"-I nwg1"*) [ -f "$T/vpn2-present" ] ;; *) [ -f "$T/vpn-present" ] ;; esac; }
dig() { [ "${DIG_FAIL:-0}" = 1 ] || echo "$DIG_IP"; }
curl() {
    out=
    while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
    if [ "${CURL_FAIL:-0}" = 1 ]; then
        [ -n "$out" ] && echo '{"prefixes":[{"ipv4Prefix":"198.51.100.7/32"}]' > "$out"
        return 1
    fi
    if [ -n "$out" ]; then echo '{"prefixes":[{"ipv4Prefix":"198.51.100.7/32"}]}' > "$out"; else echo '{"prefixes":[{"ipv4Prefix":"198.51.100.7/32"}]}'; fi
}
conntrack() { echo "$*" >> "$T/conntrack.calls"; }
flock() { [ ! -f "$T/flock-busy" ]; }
netstat() { echo 'tcp 0 0 192.168.1.1:98 0.0.0.0:* LISTEN'; }
iptables() { case "$*" in *" -C "*) return 1 ;; *) return 0 ;; esac; }
ip6tables() {
    case "$*" in
        "-C FORWARD -i br+ -j RAZVILKA_IP6") [ -f "$T/ip6.jump" ] ;;
        "-N RAZVILKA_IP6") : > "$T/ip6.rules" ;;
        "-S RAZVILKA_IP6") cat "$T/ip6.rules" ;;
        "-F RAZVILKA_IP6") : > "$T/ip6.rules" ;;
        "-A RAZVILKA_IP6 "*) echo "$*" >> "$T/ip6.rules" ;;
        "-I FORWARD -i br+ -j RAZVILKA_IP6") echo "$*" > "$T/ip6.jump" ;;
        "-D FORWARD -i br+ -j RAZVILKA_IP6") rm -f "$T/ip6.jump" ;;
        "-X RAZVILKA_IP6") rm -f "$T/ip6.rules" ;;
        *) return 0 ;;
    esac
}
ip6tables-restore() {
    [ "$1" = --noflush ] || return 1
    cat > "$T/ip6.transaction"
    [ ! -f "$T/fail-ip6-restore" ] || return 1
    grep -qx 'COMMIT' "$T/ip6.transaction" || return 1
    grep '^-A RAZVILKA_IP6 ' "$T/ip6.transaction" > "$T/ip6.new" && mv "$T/ip6.new" "$T/ip6.rules"
}
ipset() { return 0; }

# The CLI owns its traps, shell options and exit code. Give every invocation
# its own process, just as init, cron and CGI do on the router.
router() (
    export T ROOT DIG_IP
    export -f ip mock_batch ping dig curl conntrack flock netstat iptables ip6tables ip6tables-restore ipset
    if declare -F ndmc >/dev/null; then export -f ndmc; fi
    exec bash "$T/razvilka.sh" "$@"
)
source_router() {
    RC=0
    router "$@" > "$T/cli.out" 2> "$T/cli.err" || RC=$?
}
refute() {
    if "$@"; then return 1; fi
    return 0
}

kill_boot_without_vpn() {
    set -e
    setup_router kill-boot
    : > "$T/enabled"
    source_router start
    [ "$RC" -eq 0 ]
    [ "$(grep -c '^30018:' "$T/rules")" -eq 6 ]
    grep -q '^81.0.0.0/8 via 192.0.2.1 dev eth3' "$T/routes1022"
    awk '/^30022:.*lookup 1022$/{found=1} END{exit !found}' "$T/rules"
    awk '/^prohibit default( metric 100)?$/{found=1} END{exit !found}' "$T/routes1022"
    [ -f "$T/kill_active" ]
}

kill_mode_transition() {
    set -e
    setup_router change-mode
    echo soft > "$T/failmode"
    echo '198.51.100.0/24' > "$T/allow.resolved"
    router start
    grep -q '^198.51.100.0/24 via ' "$T/routes1022"
    router mode kill
    refute grep -q '^198.51.100.0/24 via ' "$T/routes1022"
    grep -q '^prohibit default' "$T/routes1022"
    grep -q '^81.0.0.0/8 via ' "$T/routes1022"
    : > "$T/conntrack.calls"
    router watchdog
    router watchdog
    [ ! -s "$T/conntrack.calls" ]
}

watchdog_logs_tunnel_transitions_once() {
    set -e
    setup_router journal
    echo direct > "$T/failmode"
    touch "$T/vpn-present"
    router start
    router watchdog
    refute grep -q 'Связь с VPN восстановлена' "$T/razvilka.log"
    rm "$T/vpn-present"
    router watchdog
    refute grep -q 'VPN не отвечает' "$T/razvilka.log"
    router watchdog
    router watchdog
    touch "$T/vpn-present"
    router watchdog
    router watchdog
    [ "$(grep -c ' VPN не отвечает$' "$T/razvilka.log")" -eq 1 ]
    [ "$(grep -c ' Связь с VPN восстановлена$' "$T/razvilka.log")" -eq 1 ]
}

disabled_killtest_leaves_routing_off() {
    set -e
    setup_router disabled-killtest
    source_router killtest 1
    [ "$RC" -ne 0 ]
    [ ! -s "$T/rules" ]
    [ ! -e "$T/kill_active" ]
    [ ! -e "$T/killtest_until" ]
}

init_preserves_preferences() {
    set -e
    setup_router service-restart
    sed 's|exec /opt/razvilka/razvilka.sh|router|g' "$ROOT/src/init/S03razvilka" > "$T/init.sh"
    touch "$T/enabled"
    (set -- restart; . "$T/init.sh")
    [ -f "$T/enabled" ]
    grep -q '^30022:.*lookup 1022' "$T/rules"
    (set -- stop; . "$T/init.sh")
    [ -f "$T/enabled" ]
    (set -- start; . "$T/init.sh")
    grep -q '^30022:.*lookup 1022' "$T/rules"
    router stop
    (set -- restart; . "$T/init.sh")
    [ ! -e "$T/enabled" ]
    [ ! -e "$T/ipv6_block" ]
    refute grep -q '^30022:' "$T/rules"
}

kill_batch_error_is_not_success() {
    set -e
    setup_router kill-error
    : > "$T/enabled"; : > "$T/vpn-present"
    echo 'throw 10.0.0.0/8' > "$T/routes1022"
    echo kill.batch > "$T/fail-batch"
    source_router killtest 1
    [ "$RC" -ne 0 ]
    [ ! -f "$T/kill_active" ]
}

foreign_rule_is_not_accepted_or_deleted() {
    set -e
    setup_router foreign-rule
    : > "$T/enabled"; : > "$T/vpn-present"
    echo 'throw 10.0.0.0/8' > "$T/routes1022"
    echo '30022: from all lookup 999' > "$T/rules"
    source_router killtest 1
    [ "$RC" -ne 0 ]
    [ ! -f "$T/kill_active" ]
    awk '/^30022:.*lookup 999$/{found=1} END{exit !found}' "$T/rules"
    source_router stop
    awk '/^30022:.*lookup 999$/{found=1} END{exit !found}' "$T/rules"
}

active_lock_rejects_second_writer() {
    set -e
    setup_router locked
    : > "$T/.lock"; : > "$T/flock-busy"
    source_router ai-on
    [ "$RC" -eq 2 ]
    [ ! -f "$T/ai_protect" ]
}

ai_routes_stay_closed_when_interface_disappears() {
    set -e
    setup_router ai-happy-path
    : > "$T/vpn-present"
    source_router ai-on
    [ "$RC" -eq 0 ]
    awk '/^203.0.113.10 dev opkgtun0 metric 10$/{found=1} END{exit !found}' "$T/routes1019"
    awk '/^prohibit 203.0.113.10 metric 100$/{found=1} END{exit !found}' "$T/routes1019"
    awk '/^prohibit 198.51.100.7 metric 100$/{found=1} END{exit !found}' "$T/routes1019"
    rm "$T/vpn-present"
    awk '$2 != "dev"' "$T/routes1019" > "$T/routes.new"; mv "$T/routes.new" "$T/routes1019"
    source_router ai-apply
    refute awk '$2 == "dev" {found=1} END{exit !found}' "$T/routes1019"
    awk '/^prohibit 203.0.113.10 metric 100$/{found=1} END{exit !found}' "$T/routes1019"
    : > "$T/vpn-present"
    source_router ai-apply
    awk '/^203.0.113.10 dev opkgtun0 metric 10$/{found=1} END{exit !found}' "$T/routes1019"
    source_router ai-off
    [ ! -s "$T/routes1019" ]
}

device_policies_are_independent_and_fail_closed() {
    set -e
    setup_router devices
    : > "$T/vpn-present"
    source_router device-set 192.168.1.50 vpn 'Рабочий Mac'
    [ "$RC" -eq 0 ]
    awk -F'|' '$1=="192.168.1.50" && $2=="vpn" && $3=="primary" && $4=="Рабочий Mac"{found=1} END{exit !found}' "$T/devices.conf"
    awk '/^30016: from 192.168.1.50 lookup 1031$/{found=1} END{exit !found}' "$T/rules"
    awk '/^default dev opkgtun0 metric 10$/{found=1} END{exit !found}' "$T/routes1031"
    awk '/^prohibit default( metric 100)?$/{found=1} END{exit !found}' "$T/routes1031"
    source_router device-set 192.168.1.60 direct 'Телевизор'
    awk '/^30016: from 192.168.1.60 lookup 1030$/{found=1} END{exit !found}' "$T/rules"
    awk '/^default via 192.0.2.1 dev eth3 metric 10$/{found=1} END{exit !found}' "$T/routes1030"
    awk '{sub(/: /,":\t"); print $0 " "}' "$T/rules" > "$T/rules.new"; mv "$T/rules.new" "$T/rules"
    source_router device-del 192.168.1.50
    [ "$RC" -eq 0 ]
    refute awk '/192.168.1.50/{found=1} END{exit !found}' "$T/rules"
    source_router device-del 192.168.1.60
    [ "$RC" -eq 0 ]
    [ ! -s "$T/rules" ]
    [ ! -s "$T/routes1030" ]
    [ ! -s "$T/routes1031" ]
}

vpn_device_stays_closed_without_server_or_ai_batch() {
    set -e
    setup_router device-no-server
    : > "$T/vpn-present"
    echo 'VPN_SERVERS_EXTRA=""' > "$T/razvilka.conf"
    source_router device-set 192.168.1.50 vpn 'Рабочий Mac'
    [ "$RC" -eq 0 ]
    awk '/^30016: from 192.168.1.50 lookup 1031$/{found=1} END{exit !found}' "$T/rules"
    awk '/^prohibit default( metric 100)?$/{found=1} END{exit !found}' "$T/routes1031"
    refute awk '/^default dev opkgtun0/{found=1} END{exit !found}' "$T/routes1031"

    setup_router ai-batch-fallback
    : > "$T/vpn-present"
    echo ai.batch > "$T/fail-batch"
    source_router ai-on
    [ "$RC" -eq 0 ]
    awk '/^30017:.*lookup 1019$/{found=1} END{exit !found}' "$T/rules"
    awk '/^prohibit 203.0.113.10 metric 100$/{found=1} END{exit !found}' "$T/routes1019"
}

doctor_reports_health_and_conflicts() {
    set -e
    setup_router doctor
    : > "$T/enabled"; : > "$T/vpn-present"
    echo '30022: from all lookup 1022' > "$T/rules"
    RC=0; router doctor > "$T/doctor.out" 2>&1 || RC=$?
    [ "$RC" -eq 0 ]
    awk '/OK: VPN-интерфейс/{found=1} END{exit !found}' "$T/doctor.out"
    awk '/OK: ip rule 30022/{found=1} END{exit !found}' "$T/doctor.out"
    echo '30022: from all lookup 999' > "$T/rules"
    RC=0; router doctor > "$T/doctor-conflict.out" 2>&1 || RC=$?
    [ "$RC" -ne 0 ]
    awk '/FAIL: ip rule 30022/{found=1} END{exit !found}' "$T/doctor-conflict.out"
}

ai_ttl_prunes_only_confirmed_stale_addresses() {
    set -e
    setup_router ai-ttl
    : > "$T/vpn-present"
    source_router ai-on
    old=$(($(date +%s)-90000))
    echo "chatgpt.com|203.0.113.10|$old|2" > "$T/ai.dns.map"
    DIG_IP=203.0.113.11; export DIG_IP
    source_router ai-refresh
    refute awk '$1 == "203.0.113.10" || $2 == "203.0.113.10" {found=1} END{exit !found}' "$T/ai.resolved"
    awk '$1 == "203.0.113.11" {found=1} END{exit !found}' "$T/ai.resolved"
    refute awk '/203.0.113.10/{found=1} END{exit !found}' "$T/routes1019"
    awk '/203.0.113.11/{found=1} END{exit !found}' "$T/routes1019"

    echo "chatgpt.com|203.0.113.11|$old|2" > "$T/ai.dns.map"
    echo '203.0.113.11' > "$T/ai.resolved"
    DIG_FAIL=1; export DIG_FAIL
    source_router ai-refresh
    awk '$1 == "203.0.113.11" {found=1} END{exit !found}' "$T/ai.resolved"
    unset DIG_FAIL
    DIG_IP=192.168.1.50; export DIG_IP
    source_router ai-refresh
    refute awk '$1 == "192.168.1.50" || $2 == "192.168.1.50" {found=1} END{exit !found}' "$T/ai.resolved"

    echo "legacy|203.0.113.12|$old|0" > "$T/ai.dns.map"
    echo '203.0.113.12' > "$T/ai.resolved"
    DIG_FAIL=1; export DIG_FAIL
    source_router ai-refresh
    awk '$1 == "203.0.113.12" {found=1} END{exit !found}' "$T/ai.resolved"
    echo '198.51.100.7' > "$T/ai.voice.resolved"
    CURL_FAIL=1; export CURL_FAIL
    source_router ai-refresh
    awk '$1 == "198.51.100.7" {found=1} END{exit !found}' "$T/ai.voice.resolved"
    unset DIG_FAIL CURL_FAIL
    DIG_IP=198.18.0.1; export DIG_IP
    source_router ai-refresh
    refute awk '$1 == "198.18.0.1" || $2 == "198.18.0.1" {found=1} END{exit !found}' "$T/ai.resolved"
}

ai_ok_checks_exact_prefixes() {
    set -e
    setup_router ai-exact-ok
    : > "$T/vpn-present"
    source_router ai-on
    awk '$2 != "160.79.104.0/23"' "$T/routes1019" > "$T/routes.new"
    echo 'prohibit 1.2.3.4' >> "$T/routes.new"; mv "$T/routes.new" "$T/routes1019"
    router status-kv > "$T/status.out"
    awk -F= '$1 == "ai_active" && $2 == 0 {found=1} END{exit !found}' "$T/status.out"
}

device_failures_preserve_lan_and_previous_policy() {
    set -e
    setup_router device-fallback-private
    : > "$T/vpn-present"
    echo devices.1031.batch > "$T/fail-batch"; echo 1 > "$T/fail-after"
    source_router device-set 192.168.1.50 vpn 'Рабочий Mac'
    [ "$RC" -eq 0 ]
    awk '/^throw 10.0.0.0\/8$/{found=1} END{exit !found}' "$T/routes1031"

    setup_router device-policy-change
    source_router device-set 192.168.1.50 direct 'Телевизор'
    cp "$T/devices.conf" "$T/devices.before"
    echo 'rule add from 192.168.1.50 table 1031 priority 30016' > "$T/fail-rule-add"
    source_router device-set 192.168.1.50 vpn 'Телевизор'
    [ "$RC" -ne 0 ]
    cmp "$T/devices.before" "$T/devices.conf"
    awk '/^30016: from 192.168.1.50 lookup 1030$/{found=1} END{exit !found}' "$T/rules"
    refute awk '/^30016: from 192.168.1.50 lookup 1031$/{found=1} END{exit !found}' "$T/rules"
}

invalid_devices_file_preserves_kernel_state() {
    set -e
    setup_router invalid-devices
    source_router device-set 192.168.1.50 direct 'Телевизор'
    printf '\n' >> "$T/devices.conf"
    source_router device-apply
    router status-kv > "$T/devices-status.out"
    awk -F= '$1 == "devices_n" && $2 == 1 {n=1} $1 == "devices_active" && $2 == 1 {a=1} END{exit !(n&&a)}' "$T/devices-status.out"
    echo 'x"><script>alert(1)</script>|vpn|bad' >> "$T/devices.conf"
    source_router device-apply
    [ "$RC" -ne 0 ]
    awk '/^30016: from 192.168.1.50 lookup 1030$/{found=1} END{exit !found}' "$T/rules"
}

backend_return_codes_cover_update_restart_and_allow() {
    set -e
    setup_router backend-codes
    : > "$T/enabled"; : > "$T/vpn-present"
    curl() {
        out=
        while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
        if [ -n "$out" ]; then awk 'BEGIN{for(i=0;i<12;i++)for(j=0;j<255;j++) print "81." i "." j ".0/24"}' > "$out"; else awk 'BEGIN{for(i=0;i<12;i++)for(j=0;j<255;j++) print "81." i "." j ".0/24"}'; fi
    }
    source_router update
    [ "$RC" -eq 0 ]
    echo 'VPN_RESTART=false' >> "$T/razvilka.conf"
    source_router vpn-restart
    [ "$RC" -ne 0 ]

    setup_router allow-error
    echo '198.51.100.8' > "$T/allow.resolved"
    DIG_FAIL=1; export DIG_FAIL
    curl() { return 1; }
    source_router allow
    [ "$RC" -ne 0 ]
    awk '$1 == "198.51.100.8" {found=1} END{exit !found}' "$T/allow.resolved"
}

multi_vpn_policies_fail_closed() {
    set -e
    setup_router multi-vpn
    echo 'VPN2_IF="nwg1"' >> "$T/razvilka.conf"
    echo 'VPN2_SERVERS_EXTRA="198.51.100.2"' >> "$T/razvilka.conf"
    : > "$T/vpn-present"; : > "$T/vpn2-present"
    source_router device-set 192.168.1.70 vpn-all primary 'Весь трафик'
    [ "$RC" -eq 0 ]
    awk '/^30016:.*from 192.168.1.70 .*lookup 1034/{found=1} END{exit !found}' "$T/rules"
    awk '/^default dev opkgtun0 metric 10$/{found=1} END{exit !found}' "$T/routes1034"
    refute awk '/^81\.0\.0\.0\/8/{found=1} END{exit !found}' "$T/routes1034"

    source_router device-set 192.168.1.71 vpn secondary 'Дополнительный VPN'
    awk '/^30016:.*from 192.168.1.71 .*lookup 1033/{found=1} END{exit !found}' "$T/rules"
    awk '/^default dev nwg1 metric 10$/{found=1} END{exit !found}' "$T/routes1033"
    awk '/^81\.0\.0\.0\/8/{found=1} END{exit !found}' "$T/routes1033"

    rm "$T/vpn-present"; rm "$T/vpn2-present"
    source_router device-apply
    refute awk '/^default dev/{found=1} END{exit !found}' "$T/routes1034"
    refute awk '/^default dev/{found=1} END{exit !found}' "$T/routes1033"
    awk '/^prohibit default( metric 100)?$/{found=1} END{exit !found}' "$T/routes1034"
    awk '/^prohibit default( metric 100)?$/{found=1} END{exit !found}' "$T/routes1033"

    : > "$T/vpn2-present"
    source_router device-set 192.168.1.73 vpn-all secondary 'Весь трафик через второй'
    awk '/^30016:.*from 192.168.1.73 .*lookup 1036/{found=1} END{exit !found}' "$T/rules"
    awk '/^default dev nwg1 metric 10$/{found=1} END{exit !found}' "$T/routes1036"
    refute awk '/^81\.0\.0\.0\/8/{found=1} END{exit !found}' "$T/routes1036"

    setup_router legacy-fallback
    echo '192.168.1.79|vpn|primary|1|Старый fallback' > "$T/devices.conf"
    source_router device-apply
    awk '/^30016:.*from 192.168.1.79 .*lookup 1031/{found=1} END{exit !found}' "$T/rules"

    setup_router legacy-device
    echo '192.168.1.80|vpn|Старый формат' > "$T/devices.conf"
    source_router device-apply
    [ "$RC" -eq 0 ]
    awk '/^30016:.*from 192.168.1.80 .*lookup 1031/{found=1} END{exit !found}' "$T/rules"
}

ipv6_block_lifecycle_and_watchdog() {
    set -e
    setup_router ipv6-block
    : > "$T/ipv6_block"
    source_router ipv6-block on
    [ "$RC" -eq 0 ]
    [ -f "$T/ip6.jump" ]
    awk '/-d fe80::\/10 -j RETURN/{found=1} END{exit !found}' "$T/ip6.rules"
    awk '/-d fc00::\/7 -j RETURN/{found=1} END{exit !found}' "$T/ip6.rules"
    awk '/-d ff00::\/8 -j RETURN/{found=1} END{exit !found}' "$T/ip6.rules"
    awk '/-p ipv6-icmp -j RETURN/{found=1} END{exit !found}' "$T/ip6.rules"
    awk '/-j DROP/{found=1} END{exit !found}' "$T/ip6.rules"
    source_router watchdog
    source_router watchdog
    [ "$(awk '/RAZVILKA_IP6/{n++} END{print n+0}' "$T/ip6.jump")" -eq 1 ]
    # Force a repair of an attached chain and check that the old DROP survives a failed commit.
    echo '-A RAZVILKA_IP6 -j RETURN' >> "$T/ip6.rules"
    cp "$T/ip6.rules" "$T/ip6.before"
    touch "$T/fail-ip6-restore"
    source_router ipv6-block on
    [ "$RC" -ne 0 ]
    cmp "$T/ip6.rules" "$T/ip6.before"
    [ -f "$T/ip6.jump" ]
    rm "$T/fail-ip6-restore"
    router watchdog
    [ "$(tail -1 "$T/ip6.rules")" = '-A RAZVILKA_IP6 -j DROP' ]
    source_router ipv6-block off
    [ ! -f "$T/ip6.jump" ]
    [ ! -f "$T/ip6.rules" ]
}

backup_restore_roundtrip_and_validation() {
    set -e
    setup_router backup-roundtrip
    : > "$T/vpn-present"
    echo '192.168.1.50|vpn-all|primary|Рабочий Mac' > "$T/devices.conf"
    mkdir -p "$T/lists"; echo 'example.com' > "$T/lists/direct.list"; echo 'chatgpt.com' > "$T/lists/vpn.list"
    echo 'admin:secret' > "$T/web.users"; echo 'token123' > "$T/csrf.token"; echo 'Контакт' > "$T/contact.txt"
    : > "$T/enabled"; : > "$T/ai_protect"; : > "$T/ipv6_block"
    TAR_BIN=tar; export TAR_BIN
    router backup > "$T/backup.out"
    archive=$(tail -n 1 "$T/backup.out")
    [ -f "$archive" ]
    find "$archive" -perm 600 | awk 'NF{found=1} END{exit !found}'
    tar tzf "$archive" | awk '/devices.conf/{devices=1} /web.users/{users=1} /lists\/direct.list/{list=1} END{exit !(devices&&users&&list)}'
    echo 'VPN_IF="nwg9"' >> "$T/razvilka.conf"; rm -f "$T/devices.conf"
    router restore "$archive" >/dev/null
    [ "$?" -eq 0 ]
    awk '/^30022:.*lookup 1022$/{found=1} END{exit !found}' "$T/rules"
    refute awk '/nwg9/{found=1} END{exit !found}' "$T/razvilka.conf"
    awk '/vpn-all/{found=1} END{exit !found}' "$T/devices.conf"
    [ -f "$T/ai_protect" ]
    [ -f "$T/ipv6_block" ]
    grep -q '^30017:.*lookup 1019' "$T/rules"

    # An incomplete, syntactically valid archive must never replace live settings.
    tar czf "$T/incomplete.tar.gz" -C "$T" failmode
    source_router restore "$T/incomplete.tar.gz"
    [ "$RC" -ne 0 ]
    grep -qx 'admin:secret' "$T/web.users"
    grep -q '^30022:.*lookup 1022' "$T/rules"

    echo 'unauthorized' > "$T/evil.txt"
    tar czf "$T/malicious.tar.gz" -C "$T" evil.txt
    RC=0; router restore "$T/malicious.tar.gz" >/dev/null 2>&1 || RC=$?
    [ "$RC" -ne 0 ]
}

neighbors_are_sanitized_and_deduplicated() {
    set -e
    setup_router neighbors
    ip() {
        case "$*" in
            "neigh show") echo '192.168.1.70 dev br0 lladdr aa:bb:cc:dd:ee:01 REACHABLE
192.168.1.70 dev br0 lladdr aa:bb:cc:dd:ee:01 STALE
169.254.190.200 dev br0 lladdr aa:bb:cc:dd:ee:03 STALE
46.39.244.1 dev eth3 lladdr aa:bb:cc:dd:ee:04 REACHABLE
999.1.1.1 dev br0 lladdr aa:bb:cc:dd:ee:02 FAILED' ;;
            *) return 0 ;;
        esac
    }
    ndmc() { return 1; }
    router neighbors > "$T/neighbors.out"
    [ "$(wc -l < "$T/neighbors.out")" -eq 1 ]
    awk -F'|' '$1 == "192.168.1.70" && $2 == "aa:bb:cc:dd:ee:01" && $3 == "" && $4 == "REACHABLE" {found=1} END{exit !found}' "$T/neighbors.out"
    refute awk -F'|' '$1 == "169.254.190.200" || $1 == "46.39.244.1" {found=1} END{exit !found}' "$T/neighbors.out"
}

traffic_stats_read_proc_net_dev() {
    set -e
    setup_router traffic-stats
    cat > "$T/proc-net-dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
opkgtun0: 1000000 100 0 0 0 0 0 0 2000000 200 0 0 0 0 0 0
    eth3: 3000000 300 0 0 0 0 0 0 4000000 400 0 0 0 0 0 0
EOF
    RZ_TEST_PROC_NET_DEV="$T/proc-net-dev"; export RZ_TEST_PROC_NET_DEV; router status-kv > "$T/traffic.out"
    awk -F= '$1 == "vpn_rx_bytes" && $2 == 1000000 {a=1} $1 == "vpn_tx_bytes" && $2 == 2000000 {b=1} $1 == "isp_rx_bytes" && $2 == 3000000 {c=1} $1 == "isp_tx_bytes" && $2 == 4000000 {d=1} END{exit !(a&&b&&c&&d)}' "$T/traffic.out"
}

run_test() {
    name=$1; shift
    local done_file="$BASE/$1.completed"
    ( set -e; "$@"; touch "$done_file" ); rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$done_file" ]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name" >&2
        FAILURES=$((FAILURES+1))
    fi
}

run_test 'strict kill is fail-closed at boot without a VPN interface' kill_boot_without_vpn
run_test 'strict mode removes soft exceptions and repeated checks preserve sessions' kill_mode_transition
run_test 'service restart and boot preserve routing and IPv6 preferences' init_preserves_preferences
run_test 'disabled scheme rejects a kill test' disabled_killtest_leaves_routing_off
run_test 'kill switch does not report success after ip-batch failure' kill_batch_error_is_not_success
run_test 'watchdog logs confirmed VPN loss and recovery only once' watchdog_logs_tunnel_transitions_once
run_test 'foreign ip rules are neither accepted nor deleted' foreign_rule_is_not_accepted_or_deleted
run_test 'active lock rejects a second writer' active_lock_rejects_second_writer
run_test 'doctor reports health and rule conflicts' doctor_reports_health_and_conflicts
run_test 'AI routes stay closed when the interface disappears' ai_routes_stay_closed_when_interface_disappears
run_test 'per-device policies are independent and fail-closed' device_policies_are_independent_and_fail_closed
run_test 'VPN device and AI remain closed during configuration failures' vpn_device_stays_closed_without_server_or_ai_batch
run_test 'AI TTL prunes stale addresses but preserves DNS failures and LAN' ai_ttl_prunes_only_confirmed_stale_addresses
run_test 'ai_ok verifies every required prefix' ai_ok_checks_exact_prefixes
run_test 'device failures preserve LAN routes and previous policy' device_failures_preserve_lan_and_previous_policy
run_test 'invalid devices.conf preserves kernel state' invalid_devices_file_preserves_kernel_state
run_test 'backend return codes cover update restart and allow' backend_return_codes_cover_update_restart_and_allow
run_test 'multi-VPN policies block equally when selected VPN fails' multi_vpn_policies_fail_closed
run_test 'IPv6 block lifecycle and watchdog are correct' ipv6_block_lifecycle_and_watchdog
run_test 'backup and restore roundtrip with archive validation' backup_restore_roundtrip_and_validation
run_test 'neighbors are sanitized and deduplicated' neighbors_are_sanitized_and_deduplicated
run_test 'traffic stats read proc net dev' traffic_stats_read_proc_net_dev
[ "$FAILURES" -eq 0 ]
