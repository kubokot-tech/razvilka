# shellcheck shell=sh
# ---------- резервное копирование и восстановление ----------

TAR_BIN=${TAR_BIN:-/opt/bin/tar}
BACKUP_DIR=$DIR/backups
BACKUP_FILES='razvilka.conf devices.conf failmode contact.txt web.users csrf.token ai_protect ipv6_block enabled kill-allow.presets lists/direct.list lists/vpn.list lists/kill-allow.list'
BACKUP_REQUIRED='razvilka.conf failmode web.users csrf.token lists/direct.list lists/vpn.list'

# Все пути заданы константами пакета. Запись через rename сохраняет прежний файл при ошибке копирования.
settings_copy() (
    from=$1; to=$2
    shift 2
    [ ! -L "$from/lists" ] && [ ! -L "$to/lists" ] && mkdir -p "$to/lists" || exit 1
    for entry in "$@"; do
        src=$from/$entry; dst=$to/$entry
        [ ! -L "$src" ] && [ ! -L "$dst" ] || exit 1
        [ ! -e "$dst" ] || [ -f "$dst" ] || exit 1
        if [ -f "$src" ]; then
            tmp=$(mktemp "$to/.copy.XXXXXX") || exit 1
            if ! cat "$src" > "$tmp" || ! mv -f "$tmp" "$dst"; then rm -f "$tmp"; exit 1; fi
        elif [ -e "$src" ]; then
            exit 1
        else
            rm -f "$dst" || exit 1
        fi
    done
)
settings_manifest() (
    cd "$1" || exit 1
    for entry in $BACKUP_REQUIRED; do [ -f "$entry" ] || exit 1; done
    for entry in $BACKUP_FILES; do
        [ -f "$entry" ] || continue
        checksum=$(sha256sum "$entry") || exit 1
        printf '%s %s\n' "$checksum" "$entry"
    done
)
backup_settings() (
    umask 077
    [ ! -L "$BACKUP_DIR" ] && mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || exit 1
    work=$(mktemp -d "$BACKUP_DIR/.creating.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    settings_copy "$DIR" "$work" $BACKUP_FILES || exit 1
    settings_manifest "$work" > "$work/manifest" || { log 'backup: отсутствуют обязательные настройки'; exit 1; }
    set -- manifest
    for entry in $BACKUP_FILES; do [ ! -f "$work/$entry" ] || set -- "$@" "$entry"; done
    "$TAR_BIN" czf "$work/archive" -C "$work" "$@" || exit 1
    archive_name=backup-$(date +%Y%m%d-%H%M%S)-${work##*.}.tar.gz
    mv "$work/archive" "$BACKUP_DIR/$archive_name" || exit 1
    log "backup: создан $BACKUP_DIR/$archive_name"
    printf '%s\n' "$BACKUP_DIR/$archive_name"
)
restore_unpack() (
    archive=$1; work=$2; target=$work/new
    # Отдельно проверяем результат tar: ошибка чтения не должна скрываться за успешным awk.
    LC_ALL=C "$TAR_BIN" tzf "$archive" > "$work/names" &&
        LC_ALL=C "$TAR_BIN" tvzf "$archive" > "$work/types" || exit 1
    awk -v names="$BACKUP_FILES manifest" '
        BEGIN { n=split(names,a," "); for (i=1;i<=n;i++) allowed[a[i]]=1 }
        $0 != "lists/" && !($0 in allowed) { exit 1 }
        seen[$0]++ { exit 1 }
    ' "$work/names" || exit 1
    awk 'substr($0,1,1) != "-" && !(substr($0,1,1) == "d" && $NF == "lists/") { exit 1 }' "$work/types" || exit 1
    mkdir -p "$target/lists" || exit 1
    while IFS= read -r entry; do
        [ "$entry" != lists/ ] || continue
        # tar отдаёт только содержимое. Владельцы, права и пути из архива не применяются.
        "$TAR_BIN" xOzf "$archive" "$entry" > "$target/$entry" || exit 1
    done < "$work/names"
    settings_manifest "$target" > "$work/check" || exit 1
    [ ! -f "$target/manifest" ] || cmp -s "$target/manifest" "$work/check"
)
restore_validate_conf() {
    # Старые архивы могут содержать произвольную команду перезапуска, уже разрешённую
    # локальным администратором. Из нового архива разрешаем только штатный init restart.
    TRUSTED_RESTART="$VPN_RESTART" awk '
        function ipv4(s, a,i) {
            if (split(s,a,".")!=4) return 0
            for (i=1;i<=4;i++) if (a[i]!~/^[0-9]+$/ || a[i]>255) return 0
            return 1
        }
        /^[[:space:]]*$/ || /^#/ {next}
        {
            pos=index($0,"="); if (!pos) exit 1
            k=substr($0,1,pos-1); v=substr($0,pos+1); q=substr(v,1,1)
            if (seen[k]++) exit 1
            if (q=="\"" || q==sprintf("%c",39)) {
                if (length(v)<2 || substr(v,length(v))!=q) exit 1
                v=substr(v,2,length(v)-2)
                if (index(v,q) || (q=="\"" && v ~ /[$`\\]/)) exit 1
            } else if (v !~ /^[A-Za-z0-9_.:\/@+-]*$/) exit 1
            if (k=="VPN_RESTART") {
                if (v!="" && v!=ENVIRON["TRUSTED_RESTART"] && v !~ /^\/opt\/etc\/init\.d\/S[0-9][0-9][A-Za-z0-9_-]+ restart$/) exit 1
            } else if (k=="LAN_IP" || k=="ALIAS_IP") {
                if (!(k=="ALIAS_IP" && v=="") && (!ipv4(v) || v=="0.0.0.0")) exit 1
            } else if (k=="VPN_SERVERS_EXTRA" || k=="VPN2_SERVERS_EXTRA") {
                n=split(v,a," "); for (i=1;i<=n;i++) if (!ipv4(a[i])) exit 1
            } else if (k=="WEB_PORT" || k=="STUB_PORT") {
                if (v!~/^[0-9]+$/ || v+0<1 || v+0>65535) exit 1
            } else if (k=="CAPTIVE_STUB") {
                if(v!="0" && v!="1") exit 1
            } else if (k ~ /^(LAN_IF|VPN_IF|ISP_IF|VPN2_IF|VPN_PROCESS|VPN2_PROCESS|HOSTNAME_LAN)$/) {
                if (v=="" && k ~ /^(LAN_IF|VPN_IF|ISP_IF)$/) exit 1
                if (v!="" && v!~/^[A-Za-z0-9_][A-Za-z0-9_.+-]*$/) exit 1
            } else exit 1
        }
    ' "$1"
}
restore_validate_settings() (
    target=$1
    [ -s "$target/razvilka.conf" ] && restore_validate_conf "$target/razvilka.conf" || exit 1
    DEVICES_FILE=$target/devices.conf
    devices_validate || exit 1
    awk 'NR != 1 || $0 !~ /^(direct|soft|kill)$/ {bad=1} END{exit (bad || NR!=1)}' "$target/failmode" &&
        awk 'NR != 1 || $0 !~ /^[A-Za-z0-9]+$/ {bad=1} END{exit (bad || NR!=1)}' "$target/csrf.token" &&
        awk '!/^[^:[:space:]]+:.+$/ {bad=1} END{exit (bad || !NR)}' "$target/web.users"
)
restore_web_values() (
    DIR=$1; load_router_config || exit 1
    printf '%s|%s|%s|%s|%s\n' "$LAN_IP" "$WEB_PORT" "$STUB_PORT" "$ALIAS_IP" "$HOSTNAME_LAN"
)
restore_prepare_web() (
    work=$1
    if [ ! -f "$DIR/lighttpd.conf.in" ]; then
        [ "$(restore_web_values "$work/new")" = "$(restore_web_values "$DIR")" ]
        exit $?
    fi
    tmpl=$DIR/lighttpd.conf.in
    DIR=$work/new; load_router_config || exit 1
    if [ -n "$ALIAS_IP" ]; then alias_edit="s/@ALIAS_IP@/$ALIAS_IP/g"; else alias_edit='/^#ALIAS_BEGIN/,/^#ALIAS_END/d'; fi
    sed -e "s/@LAN_IP@/$LAN_IP/g" -e "s/@WEB_PORT@/$WEB_PORT/g" -e "s/@STUB_PORT@/$STUB_PORT/g" -e "$alias_edit" "$tmpl" > "$work/new/lighttpd.conf" || exit 1
    "${RZ_TEST_LIGHTTPD:-/opt/sbin/lighttpd}" -tt -f "$work/new/lighttpd.conf"
)
restore_apply() (
    previous=$1
    IFS='|' read -r prev_lan prev_web prev_stub prev_alias prev_host <<EOF
$(restore_web_values "$previous")
EOF
    old_lan_if=$(DIR=$previous; load_router_config && printf '%s' "$LAN_IF") || exit 1
    load_router_config || exit 1
    rm -f "$DIR/devices.state" || exit 1
    if [ -f "$ENABLED" ]; then
        start_main || exit 1
    elif [ -f "$previous/enabled" ]; then
        stop_main || exit 1
    else
        device_apply || exit 1
    fi
    if ai_is_on; then
        if [ ! -f "$ENABLED" ]; then ai_refresh && ai_apply || exit 1; fi
    elif [ -f "$previous/ai_protect" ]; then ai_off || exit 1; fi
    if [ -f "$previous/ipv6_block" ] && { [ "$old_lan_if" != "$LAN_IF" ] || [ ! -f "$IPV6_BLOCK_FILE" ]; }; then
        ( LAN_IF=$old_lan_if; ipv6_block_off ) || exit 1
    fi
    ipv6_block_on && make_stub || exit 1
    if [ "$prev_alias" != "$ALIAS_IP" ] && [ -n "$prev_alias" ]; then
        if ip -4 addr show br0 | grep -Fq " $prev_alias/"; then ip addr del "$prev_alias/32" dev br0 || exit 1; fi
    fi
    if [ -n "$ALIAS_IP" ] && ! ip -4 addr show br0 | grep -Fq " $ALIAS_IP/"; then
        ip addr add "$ALIAS_IP/32" dev br0 || exit 1
    fi
    if [ "$prev_alias|$prev_host" != "$ALIAS_IP|$HOSTNAME_LAN" ]; then
        if [ -n "$prev_alias" ] && [ -n "$prev_host" ]; then
            for host in "$prev_host" "${prev_host%.*}.local"; do ndmc -c "no ip host $host $prev_alias" || exit 1; done
        fi
        if [ -n "$ALIAS_IP" ] && [ -n "$HOSTNAME_LAN" ]; then
            for host in "$HOSTNAME_LAN" "${HOSTNAME_LAN%.*}.local"; do ndmc -c "ip host $host $ALIAS_IP" || exit 1; done
        fi
        ndmc -c 'system configuration save' || exit 1
    fi
    if [ -f "$DIR/lighttpd.conf" ] && { ! cmp -s "$previous/lighttpd.conf" "$DIR/lighttpd.conf" || ! cmp -s "$previous/web.users" "$DIR/web.users"; }; then
        # Фоновый lighttpd не должен наследовать дескриптор блокировки вызывающего CLI.
        LOCK_HELD=1 "${RZ_TEST_WEB_INIT:-/opt/etc/init.d/S81razvilka-web}" restart 9>&- || exit 1
    fi
    flush_flows
)
restore_settings() (
    umask 077
    [ -f "$1" ] && [ ! -L "$1" ] || { echo 'restore: архив не найден или является симлинком' >&2; exit 1; }
    work=$(mktemp -d "$DIR/.restore.XXXXXX") || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    cp "$1" "$work/archive" && restore_unpack "$work/archive" "$work" &&
        restore_validate_settings "$work/new" && restore_prepare_web "$work" || {
        echo 'restore: архив неполон или содержит недопустимые настройки' >&2; exit 1
    }
    restore_files=$BACKUP_FILES
    [ ! -f "$work/new/lighttpd.conf" ] || restore_files="$restore_files lighttpd.conf"
    settings_copy "$DIR" "$work/old" $restore_files || exit 1
    # Старый конфиг веб-сервера нужен и для сравнения при обновлении со старой версии.
    if [ -f "$DIR/lighttpd.conf" ] && [ ! -f "$work/old/lighttpd.conf" ]; then
        cp "$DIR/lighttpd.conf" "$work/old/lighttpd.conf" || exit 1
    fi
    restore_finish() {
        result=$?
        trap - EXIT HUP INT TERM
        if [ "$result" != 0 ]; then
            if ! settings_copy "$work/old" "$DIR" $restore_files || ! restore_apply "$work/new"; then
                echo "restore: откат не завершён; исходные файлы сохранены в $work/old" >&2
                log "backup: ошибка отката, исходные файлы в $work/old"
                exit 1
            fi
            log 'backup: прежние настройки возвращены'
        fi
        rm -rf "$work"
        exit "$result"
    }
    trap 'restore_finish' EXIT
    settings_copy "$work/new" "$DIR" $restore_files && restore_apply "$work/old" || exit 1
    log 'backup: настройки восстановлены'
)
