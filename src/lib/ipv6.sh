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
