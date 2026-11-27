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
