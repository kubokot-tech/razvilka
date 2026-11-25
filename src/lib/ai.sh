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

