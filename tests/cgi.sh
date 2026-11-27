#!/bin/bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/razvilka-cgi.XXXXXX") || exit 1
mkdir -p "$T/lists"
cp "$ROOT/src/lib/journal.awk" "$T/journal.awk"
trap 'rm -rf "$T"' EXIT INT TERM
FAILURES=0
TOKEN=testtoken123
printf '%s\n' "$TOKEN" > "$T/csrf.token"
cat > "$T/fvpn.sh" <<'EOF'
#!/bin/sh
case "$1" in
    status-kv)
        [ -f "$RZ_TEST_DIR/disabled" ] && echo 'enabled=0' || echo 'enabled=1'; [ -f "$RZ_TEST_DIR/rule-off" ] && echo 'rule=0' || echo 'rule=1'; echo 'tunnel=1'; echo 'kill=0'; echo 'killtest=0'
        [ -f "$RZ_TEST_DIR/vpn2-enabled" ] && { echo 'vpn2_if=nwg1'; echo 'vpn2_tunnel=1'; }
        [ -f "$RZ_TEST_DIR/ipv6_block" ] && echo 'ipv6_blocked=1' || echo 'ipv6_blocked=0'
        echo 'vpn_rx_bytes=1000000'; echo 'vpn_tx_bytes=2000000'; echo 'isp_rx_bytes=3000000'; echo 'isp_tx_bytes=4000000'
        echo 'failmode=direct'; echo 'fails=0'; echo 'vpn_if=opkgtun0'; echo 'ai_routes=42'; echo 'ai_failed=0'
        [ -f "$RZ_TEST_DIR/ai_protect" ] && { echo 'ai_protect=1'; echo 'ai_active=1'; } || { echo 'ai_protect=0'; echo 'ai_active=0'; }
        echo "now=$(date +%s)"
        ;;
    start) [ -f "$RZ_TEST_DIR/busy-start" ] && exit 2; echo start >> "$RZ_TEST_DIR/actions" ;;
    killtest) [ -f "$RZ_TEST_DIR/fail-kill" ] && exit 1; echo killtest >> "$RZ_TEST_DIR/actions" ;;
    lists) [ -f "$RZ_TEST_DIR/busy-lists" ] && exit 2; echo lists >> "$RZ_TEST_DIR/actions" ;;
    ai-on) [ -f "$RZ_TEST_DIR/busy-ai" ] && exit 2; echo ai-on >> "$RZ_TEST_DIR/actions"; touch "$RZ_TEST_DIR/ai_protect" ;;
    ai-off) echo ai-off >> "$RZ_TEST_DIR/actions"; rm -f "$RZ_TEST_DIR/ai_protect" ;;
    device-set) echo "device-set $2 $3 $4 $5" >> "$RZ_TEST_DIR/actions" ;;
    device-del) echo "device-del $2" >> "$RZ_TEST_DIR/actions" ;;
    doctor) echo 'OK: test diagnostic' ;;
    backup) mkdir -p "$RZ_TEST_DIR/backups"; echo 'secret-backup' > "$RZ_TEST_DIR/backups/backup-test.tar.gz"; echo "$RZ_TEST_DIR/backups/backup-test.tar.gz" ;;
    ipv6-block) echo "ipv6-block $2" >> "$RZ_TEST_DIR/actions"; [ "$2" = on ] && touch "$RZ_TEST_DIR/ipv6_block" || rm -f "$RZ_TEST_DIR/ipv6_block" ;;
    lookup)
        printf '%s|%s|%s\n' "$2" "${3:-}" "${4:-}" >> "$RZ_TEST_DIR/lookup.calls"
        case "$2" in
            203.0.113.10) echo 'dev=opkgtun0'; echo 'table=1019'; echo 'match_direct=secret-direct.example'; echo 'ru=0'; echo 'ai=1' ;;
            203.0.113.20) echo 'dev=eth0'; echo 'table=1022'; echo 'match_vpn=secret-vpn.example'; echo 'ru=1'; echo 'ai=0' ;;
            203.0.113.30) echo 'dev='; echo 'blocked=1'; echo 'table=1019'; echo 'ru=0'; echo 'ai=1' ;;
        esac
        ;;
    presets) ;;
    neighbors) echo '192.168.1.70|aa:bb:cc:dd:ee:01|Рабочий Mac|arp' ;;
    *) echo "$*" >> "$RZ_TEST_DIR/actions" ;;
esac
EOF
chmod +x "$T/fvpn.sh"
cat > "$T/dig.sh" <<'EOF'
#!/bin/sh
case "$4" in
    mixed.example) printf '%s\n' '203.0.113.10' '203.0.113.20' ;;
    blocked.example) echo '203.0.113.30' ;;
esac
EOF
chmod +x "$T/dig.sh"
export RZ_TEST_DIR="$T" RZ_TEST_FVPN="$T/fvpn.sh" RZ_TEST_LOG=/dev/null RZ_TEST_DIG="$T/dig.sh"
cat > "$T/flock.sh" <<'EOF'
#!/bin/sh
[ ! -e "$RZ_TEST_DIR/writer-locked" ]
EOF
chmod +x "$T/flock.sh"
export RZ_TEST_FLOCK="$T/flock.sh"
export HTTP_HOST=192.168.1.1:98 REMOTE_ADDR=192.168.1.32

get_page() {
    REQUEST_METHOD=GET QUERY_STRING="${2:-}" HTTP_ORIGIN= HTTP_COOKIE= sh "$ROOT/src/www/index.sh" > "$T/$1"
}
get_status() {
    REQUEST_METHOD=GET QUERY_STRING="${2:-}" HTTP_ORIGIN= HTTP_COOKIE= sh "$ROOT/src/www/status.sh" > "$T/$1"
}
post_page() {
    name=$1; body=$2; origin=$3; cookie=$4
    printf '%s' "$body" | REQUEST_METHOD=POST CONTENT_LENGTH=${#body} HTTP_ORIGIN="$origin" HTTP_COOKIE="$cookie" \
        sh "$ROOT/src/www/index.sh" > "$T/$name"
}
run_test() {
    name=$1; shift
    ( "$@" ); rc=$?
    if [ "$rc" -eq 0 ]; then echo "PASS: $name"; else echo "FAIL: $name" >&2; FAILURES=$((FAILURES+1)); fi
}

get_sets_csrf_cookie() {
    set -e
    get_page get.out
    awk -v token="$TOKEN" '/^Set-Cookie: razvilka_csrf=/ && index($0,token) && /HttpOnly/ && /SameSite=Strict/{found=1} END{exit !found}' "$T/get.out"
}
post_requires_token() {
    set -e
    post_page denied.out action=ai_save 'http://192.168.1.1:98' ''
    awk '/^Status: 403/{found=1} END{exit !found}' "$T/denied.out"
    [ ! -f "$T/actions" ]
}
post_requires_same_origin() {
    set -e
    post_page origin.out 'action=ai_save&ai_protect=1' 'https://attacker.example' "razvilka_csrf=$TOKEN"
    awk '/^Status: 403/{found=1} END{exit !found}' "$T/origin.out"
    [ ! -f "$T/actions" ]
}
post_accepts_valid_request() {
    set -e
    post_page allowed.out 'action=ai_save&ai_protect=1' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/^Status: 303/{status=1} /^Location: \?msg=ai_on/{location=1} END{exit !(status&&location)}' "$T/allowed.out"
    awk '/^ai-on$/{found=1} END{exit !found}' "$T/actions"
}

device_form_saves_and_deletes() {
    set -e
    post_page device-save.out 'action=device_save&ip=192.168.1.50&policy=vpn&name=Mac' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=device_saved/{found=1} END{exit !found}' "$T/device-save.out"
    awk '/^device-set 192.168.1.50 vpn primary Mac$/{found=1} END{exit !found}' "$T/actions"
    post_page device-delete.out 'action=device_delete&ip=192.168.1.50' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=device_deleted/{found=1} END{exit !found}' "$T/device-delete.out"
    awk '/^device-del 192.168.1.50$/{found=1} END{exit !found}' "$T/actions"
}
doctor_button_writes_report() {
    set -e
    post_page doctor-post.out 'action=doctor' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=doctor/{found=1} END{exit !found}' "$T/doctor-post.out"
    awk '/OK: test diagnostic/{found=1} END{exit !found}' "$T/doctor.txt"
    get_page doctor-page.out 'msg=doctor'
    awk '/Диагностика/ && /OK: test diagnostic/{found=1} END{exit !found}' "$T/doctor-page.out"
}
device_table_is_rendered() {
    set -e
    printf '192.168.1.50|vpn|Рабочий Mac\n' > "$T/devices.conf"
    get_page devices.out
    awk '/Дополнительный VPN/ && /не настроен/{found=1} END{exit !found}' "$T/devices.out"
    awk '/<table>/{table=1} /Рабочий Mac/{name=1} /value="vpn" selected/{policy=1} END{exit !(table&&name&&policy)}' "$T/devices.out"
    awk '/role="region"/ && /aria-labelledby="devices-title"/{found=1} END{exit !found}' "$T/devices.out"
}

rendered_ai_form_contains_action() {
    set -e
    get_page ai-form.out
    awk '/aria-labelledby="ai-title"/{form=1} form && /type="hidden" name="action" value="ai_save"/{action=1} form && /type="submit"/{submit=1} END{exit !(form&&action&&submit)}' "$T/ai-form.out"
}
failed_actions_show_busy_or_error() {
    set -e
    : > "$T/busy-start"
    post_page busy.out 'action=start' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=busy/{found=1} END{exit !found}' "$T/busy.out"
    awk '/Location: \?msg=started/{found=1} END{exit found}' "$T/busy.out"
    : > "$T/fail-kill"
    post_page failed.out 'action=killtest' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=action_error/{found=1} END{exit !found}' "$T/failed.out"
    awk '/Location: \?msg=killtest/{found=1} END{exit found}' "$T/failed.out"
}
invalid_device_is_not_rendered() {
    set -e
    printf '%s\n' 'x"><script>alert(1)</script>|vpn|bad' '192.168.1.50|vpn|Рабочий Mac' > "$T/devices.conf"
    get_page invalid-device.out
    awk '/<script>alert\(1\)/{found=1} END{exit found}' "$T/invalid-device.out"
    awk '/Рабочий Mac/{found=1} END{exit !found}' "$T/invalid-device.out"
    awk '/headers="dev-col-policy"/{found=1} END{exit !found}' "$T/invalid-device.out"
}

public_status_requires_rule_for_success() {
    set -e
    : > "$T/rule-off"
    REQUEST_METHOD=GET QUERY_STRING= HTTP_ORIGIN= HTTP_COOKIE= sh "$ROOT/src/www/status.sh" > "$T/status-rule.out"
    awk '/Основной VPN работает/{found=1} END{exit found}' "$T/status-rule.out"
    awk '/VPN отвечает, маршрут ещё не включён/{found=1} END{exit !found}' "$T/status-rule.out"
}
vpn_list_device_and_google_preset() {
    set -e
    post_page tv.out 'action=device_save&ip=192.168.1.60&policy=vpn-list&vpn=primary&name=TV' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    grep -Fq 'Location: ?msg=device_saved' "$T/tv.out"
    grep -Fxq 'device-set 192.168.1.60 vpn-list primary TV' "$T/actions"
    echo '192.168.1.60|vpn-list|primary|TV' > "$T/devices.conf"
    echo 'unknown.example' > "$T/vpn.missing"
    get_page tv-form.out
    grep -Fq 'value="vpn-list" selected>Всё напрямую, кроме списка VPN' "$T/tv-form.out"
    grep -Fq 'value="vpn-list">Всё напрямую, кроме списка VPN' "$T/tv-form.out"
    grep -Fq 'unknown.example' "$T/tv-form.out"
    grep -Fq 'name="add_google" value="1"' "$T/tv-form.out"
    rm "$T/vpn.missing"
    post_page list.out 'action=save_list&list=vpn&content=example.com' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    [ "$(cat "$T/lists/vpn.list")" = 'example.com' ]
    for content in 'example.com' 'example.com%0Aas15169%20%23%20Google'; do
        post_page google.out "action=save_list&list=vpn&add_google=1&content=$content" 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
        grep -Fq 'Location: ?msg=saved' "$T/google.out"
        grep -Fxq 'example.com' "$T/lists/vpn.list"
        [ "$(grep -c '^AS15169' "$T/lists/vpn.list")" = 1 ]
    done
}

list_busy_preserves_context() {
    set -e
    : > "$T/busy-lists"
    post_page list-busy.out 'action=add_entry&list=vpn&entry=chatgpt.com&host=chatgpt.com' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=apply_busy&host=chatgpt.com#check/{found=1} END{exit !found}' "$T/list-busy.out"
    awk '/^chatgpt.com/{found=1} END{exit !found}' "$T/lists/vpn.list"
}
mobile_headers_stay_in_accessibility_tree() {
    set -e
    get_page mobile.out
    awk '/\.table-wrapper thead\{position:absolute/{found=1} END{exit !found}' "$T/mobile.out"
    awk '/\.table-wrapper thead\{display:none/{found=1} END{exit found}' "$T/mobile.out"
}
mobile_device_cards_do_not_clip_or_stick() {
    set -e
    printf '192.168.1.50|vpn|Рабочий Mac\n192.168.1.51|direct|Домашний телевизор\n' > "$T/devices.conf"
    get_page mobile-devices.out
    awk '
        index($0, ".table-container{container-type:inline-size}") { parent=1 }
        /<div class="table-container">/ { wrapper=1 }
        /@container \(width < 600px\)\{/ { mobile=1 }
        mobile && index($0, ".table-wrapper{max-block-size:none;overflow:visible}") { flow=1 }
        mobile && index($0, ".table-wrapper tbody th{position:static") { unsticky=1 }
        mobile && /^\}/ { mobile=0 }
        END { exit !(parent && wrapper && flow && unsticky) }
    ' "$T/mobile-devices.out"
    awk 'index($0, ".table-wrapper{overflow:auto") && index($0, "container-type") { found=1 } END { exit found }' "$T/mobile-devices.out"
    [ "$(awk '{count += gsub(/<tr><th scope="row"/, "&")} END{print count+0}' "$T/mobile-devices.out")" -eq 2 ]
}
mobile_status_link_keeps_its_label() {
    set -e
    get_page mobile-status.out
    awk 'index($0, ".top .ref span{display:none}") { found=1 } END { exit found }' "$T/mobile-status.out"
    awk 'index($0, ".top .refresh span{display:none}") { rule=1 } /<a class="ref refresh" href="\?">/ { link=1 } END { exit !(rule && link) }' "$T/mobile-status.out"
}
admin_lookup_precedes_management_and_settings() {
    set -e
    get_page order.out
    awk '
        index($0, "<div class=\"tiles\">") && !tiles { tiles=NR }
        index($0, "<section class=\"card check\" id=\"check\">") && !check { check=NR }
        index($0, ">Управление</h2>") && !manage { manage=NR }
        index($0, "<section class=\"card\" id=\"devices\">") && !devices { devices=NR }
        index($0, ">Ручные списки</h2>") && !lists { lists=NR }
        index($0, "<section class=\"card\" id=\"journal\"") && !journal { journal=NR }
        END { exit !(tiles && tiles < check && check < manage && manage < devices && devices < lists && lists < journal) }
    ' "$T/order.out"
}
public_lookup_is_read_only() {
    set -e
    get_status public-readonly.out 'host=mixed.example'
    awk '
        index($0, "<section class=\"lookup\" id=\"check\"") { section=1 }
        section && index($0, "<form method=\"get\"") { get=1 }
        section && index($0, "for=\"status-host\"") { label=1 }
        END { exit !(section && get && label) }
    ' "$T/public-readonly.out"
    awk '/method="post"|add_entry|<textarea|Добавить в список|secret-direct\.example|secret-vpn\.example/{found=1} END{exit found}' "$T/public-readonly.out"
}
public_lookup_summarizes_mixed_routes() {
    set -e
    get_status public-mixed.out 'host=mixed.example'
    grep -qxF '203.0.113.10|192.168.1.32|brief' "$T/lookup.calls"
    awk '
        index($0, "<b>mixed.example</b>") && index($0, "2 адреса") && index($0, "1 через VPN") && index($0, "1 напрямую") { summary=1 }
        index($0, "203.0.113.10") && index($0, "Адрес входит в список защиты Claude Code и ChatGPT") { vpn=1 }
        index($0, "203.0.113.20") && index($0, "Российская сеть") && index($0, "напрямую") { direct=1 }
        END { exit !(summary && vpn && direct) }
    ' "$T/public-mixed.out"
}
public_lookup_handles_ai_block_without_device() {
    set -e
    get_status public-blocked.out 'host=blocked.example'
    awk '
        index($0, "<b>blocked.example</b>") && index($0, "1 адрес") && index($0, "заблокировано") { summary=1 }
        index($0, "203.0.113.30") && index($0, "прямой доступ закрыт") && index($0, "Claude Code и ChatGPT") { reason=1 }
        END { exit !(summary && reason) }
    ' "$T/public-blocked.out"
}
public_lookup_reports_missing_addresses() {
    set -e
    get_status public-missing.out 'host=missing.example'
    awk 'index($0, "<b>missing.example</b>") && index($0, "Не удалось найти адрес") {found=1} END{exit !found}' "$T/public-missing.out"
}

multi_vpn_device_form_works() {
    set -e
    : > "$T/vpn2-enabled"
    post_page multi-vpn-save.out 'action=device_save&ip=192.168.1.70&policy=vpn-all&vpn=secondary&name=Work' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=device_saved/{found=1} END{exit !found}' "$T/multi-vpn-save.out"
    awk '/^device-set 192.168.1.70 vpn-all secondary Work$/{found=1} END{exit !found}' "$T/actions"
    printf '192.168.1.70|vpn-all|secondary|Work\n' > "$T/devices.conf"
    get_page multi-vpn-table.out
    awk '/value="vpn-all" selected/{policy=1} /value="secondary" selected>Дополнительный: nwg1/{vpn=1} END{exit !(policy&&vpn)}' "$T/multi-vpn-table.out"
    awk '/name="fallback"/{found=1} END{exit found}' "$T/multi-vpn-table.out"
}

ipv6_form_toggles_block() {
    set -e
    : > "$T/ipv6_block"
    get_page ipv6-form.out
    awk '/name="action" value="ipv6_save"/{action=1} /type="checkbox" switch name="ipv6_block"[^>]* checked>/{checkbox=1} END{exit !(action&&checkbox)}' "$T/ipv6-form.out"
    post_page ipv6-on.out 'action=ipv6_save&ipv6_block=1' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=ipv6_on/{found=1} END{exit !found}' "$T/ipv6-on.out"
    awk '/^ipv6-block on$/{found=1} END{exit !found}' "$T/actions"
    post_page ipv6-off.out 'action=ipv6_save' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=ipv6_off/{found=1} END{exit !found}' "$T/ipv6-off.out"
    [ ! -f "$T/ipv6_block" ]
}

backup_button_and_download_are_secure() {
    set -e
    post_page backup-create.out 'action=backup' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/Location: \?msg=backup_done/{found=1} END{exit !found}' "$T/backup-create.out"
    get_page backup-link.out 'msg=backup_done&file=backup-test.tar.gz'
    awk '/href="\/backup\?f=backup-test.tar.gz"/{found=1} END{exit !found}' "$T/backup-link.out"
    REMOTE_USER= REQUEST_METHOD=GET QUERY_STRING='f=backup-test.tar.gz' sh "$ROOT/src/www/backup.sh" > "$T/no-user.out"
    grep -q '^Status: 403' "$T/no-user.out"
    REMOTE_USER=admin REQUEST_METHOD=GET QUERY_STRING='f=backup-test.tar.gz' sh "$ROOT/src/www/backup.sh" > "$T/download.out"
    awk '/Content-Type: application\/gzip/{type=1} /Content-Disposition: attachment; filename="backup-test.tar.gz"/{disp=1} /Cache-Control: no-store/{cache=1} /Referrer-Policy: no-referrer/{ref=1} END{exit !(type&&disp&&cache&&ref)}' "$T/download.out"
    awk '/secret-backup/{found=1} END{exit !found}' "$T/download.out"
    REMOTE_USER=admin REQUEST_METHOD=GET QUERY_STRING='f=../../etc/passwd' sh "$ROOT/src/www/backup.sh" > "$T/traversal.out"
    awk '/Status: 404/{found=1} END{exit !found}' "$T/traversal.out"
    REQUEST_METHOD=POST CONTENT_LENGTH=0 QUERY_STRING= sh "$ROOT/src/www/backup.sh" > "$T/post-download.out"
    awk '/Status: 405/{found=1} END{exit !found}' "$T/post-download.out"
}

admin_journal_pages() {
    set -e
    export RZ_TEST_LOG="$T/journal.log"
    awk 'BEGIN{for(i=1;i<=56;i++) printf "2026-11-25 10:12:00 Строка %03d\n", i}' > "$RZ_TEST_LOG"
    for msg in 'VPN не отвечает' 'kill switch: soft' 'Связь с VPN восстановлена' 'списки: ошибки ip -batch <router> & DNS'; do
        echo "2026-11-25 10:12:00 $msg" >> "$RZ_TEST_LOG"
    done
    get_page journal.out
    grep -qF 'href="/log/download"' "$T/journal.out"
    grep -qF '/admin?log_end=35#journal' "$T/journal.out"
    awk '
        /<li class="entry / {rows++}
        /entry error/ && /Ошибка</ && /ошибки ip -batch &lt;router&gt; &amp; DNS/ {failure=rows}
        /entry ok/ && /Норма</ && /Связь с VPN восстановлена/ {recovery=rows}
        /entry warn/ && /Внимание</ && /Включена блокировка с исключениями/ {block=rows}
        /entry error/ && /VPN не отвечает/ {outage=rows}
        /Строка 036/ {last=rows}
        END {exit !(rows==25 && failure==1 && recovery==2 && block==3 && outage==4 && last==25)}
    ' "$T/journal.out"
    echo 'Новая запись' >> "$RZ_TEST_LOG"
    get_page older.out 'log_end=35'
    awk '/<li class="entry /{rows++} /Строка 035/{first=rows} /Строка 011/{last=rows}
        END{exit !(rows==25 && first==1 && last==25)}' "$T/older.out"
    grep -qF '/admin?log_end=60#journal">Новее' "$T/older.out"
    grep -qF '/admin?log_end=10#journal">Раньше' "$T/older.out"
    get_page oldest.out 'log_end=10'
    [ "$(grep -c '<li class="entry ' "$T/oldest.out")" -eq 10 ]
    if grep -q '>Раньше<' "$T/oldest.out"; then return 1; fi
    echo 'После ротации' > "$RZ_TEST_LOG"
    get_page rotated.out 'log_end=35'
    grep -q 'entry-message">После ротации<' "$T/rotated.out"
    rm "$RZ_TEST_LOG"
    get_page empty.out
    grep -q 'Журнал пока пуст' "$T/empty.out"
    if grep -q 'href="/log/download"' "$T/empty.out"; then return 1; fi
}

public_journal_pages() {
    set -e
    export RZ_TEST_LOG="$T/public.log"
    awk 'BEGIN{for(i=0;i<5;i++){
        print "2026-11-25 10:00:00 туннель не отвечает: private.example"
        print "2026-11-25 10:00:01 туннель жив: private.example"
        print "2026-11-25 10:00:02 списки: ошибка ip -batch private.example"
    }}' > "$RZ_TEST_LOG"
    get_status events.out
    grep -qF '/status?log_end=2#journal' "$T/events.out"
    grep -qF 'href="/admin#journal"' "$T/events.out"
    grep -q 'http-equiv="refresh"' "$T/events.out"
    [ "$(grep -c '<li class="entry ' "$T/events.out")" -eq 8 ]
    get_status old-events.out 'log_end=2'
    grep -q 'entry error.*VPN не отвечает' "$T/old-events.out"
    grep -q 'entry ok.*Связь с VPN восстановлена' "$T/old-events.out"
    grep -qF '/status#journal">Новее' "$T/old-events.out"
    [ "$(grep -c '<li class="entry ' "$T/old-events.out")" -eq 2 ]
    if grep -qE 'private[.]example|href="/log/download"' "$T/events.out" "$T/old-events.out"; then return 1; fi
    if grep -q 'http-equiv="refresh"' "$T/old-events.out"; then return 1; fi
}

log_download_returns_retained_file() {
    set -e
    export RZ_TEST_LOG="$T/download.log"
    printf 'Строка 1\r\n\n<&>\tбез завершающего перевода строки' > "$RZ_TEST_LOG"
    REMOTE_USER= REQUEST_METHOD=GET sh "$ROOT/src/www/log.sh" > "$T/denied-log.out"
    grep -q '^Status: 403' "$T/denied-log.out"
    REMOTE_USER=admin REQUEST_METHOD=POST sh "$ROOT/src/www/log.sh" > "$T/post-log.out"
    grep -q '^Status: 405' "$T/post-log.out"
    REMOTE_USER=admin REQUEST_METHOD=GET sh "$ROOT/src/www/log.sh" > "$T/full-log.out"
    grep -q '^Content-Disposition: attachment; filename="razvilka.log"' "$T/full-log.out"
    grep -q '^Cache-Control: no-store' "$T/full-log.out"
    # Skip exactly the headers, preserving all body bytes (including the last line).
    body_start=$(awk '/^\r?$/{print NR+1; exit}' "$T/full-log.out")
    tail -n +"$body_start" "$T/full-log.out" | cmp - "$RZ_TEST_LOG"
    mv "$RZ_TEST_LOG" "$RZ_TEST_LOG.saved"
    REMOTE_USER=admin REQUEST_METHOD=GET sh "$ROOT/src/www/log.sh" > "$T/missing-log.out"
    grep -q '^Status: 404' "$T/missing-log.out"
    ln -s "$RZ_TEST_LOG.saved" "$RZ_TEST_LOG"
    REMOTE_USER=admin REQUEST_METHOD=GET sh "$ROOT/src/www/log.sh" > "$T/symlink-log.out"
    grep -q '^Status: 404' "$T/symlink-log.out"
}

neighbor_option_populates_device_form() {
    set -e
    get_page neighbor-form.out
    awk '/name="neighbor"/{select=1} /192.168.1.70 — Рабочий Mac \(aa:bb:cc:dd:ee:01\)/{option=1} END{exit !(select&&option)}' "$T/neighbor-form.out"
    post_page neighbor-save.out 'action=device_save&neighbor=192.168.1.70&policy=vpn&vpn=primary' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    awk '/^device-set 192.168.1.70 vpn primary Рабочий Mac$/{found=1} END{exit !found}' "$T/actions"
}

traffic_cards_show_formatted_bytes() {
    set -e
    get_page traffic.out
    awk '/id="traffic"/{card=1} /1.0 МБ/{vpnrx=1} /2.0 МБ/{vpntx=1} /3.0 МБ/{isprx=1} /4.0 МБ/{isptx=1} END{exit !(card&&vpnrx&&vpntx&&isprx&&isptx)}' "$T/traffic.out"
    REQUEST_METHOD=GET QUERY_STRING= HTTP_ORIGIN= HTTP_COOKIE= sh "$ROOT/src/www/status.sh" > "$T/traffic-status.out"
    awk '/VPN · получено \/ отправлено/ && /1.0 МБ \/ 2.0 МБ/{found=1} END{exit !found}' "$T/traffic-status.out"
}

disabled_scheme_hides_killtest() {
    set -e
    touch "$T/disabled"
    get_page disabled.out
    rm "$T/disabled"
    grep -q 'value="start"' "$T/disabled.out"
    awk '/value="killtest"/{found=1} END{exit found}' "$T/disabled.out"
}

busy_writer_preserves_lists() {
    set -e
    touch "$T/writer-locked"
    post_page locked-list.out 'action=add_entry&list=vpn&entry=locked.example' 'http://192.168.1.1:98' "razvilka_csrf=$TOKEN"
    rm "$T/writer-locked"
    grep -q 'Location: ?msg=busy' "$T/locked-list.out"
    if [ -f "$T/lists/vpn.list" ]; then
        awk '/locked.example/{found=1} END{exit found}' "$T/lists/vpn.list"
    fi
}

run_test 'busy writer preserves saved settings' busy_writer_preserves_lists
run_test 'disabled scheme hides kill switch test' disabled_scheme_hides_killtest
run_test 'GET sets a strict HttpOnly CSRF cookie' get_sets_csrf_cookie
run_test 'POST without a CSRF token is rejected' post_requires_token
run_test 'POST from another origin is rejected' post_requires_same_origin
run_test 'valid same-origin POST is accepted' post_accepts_valid_request
run_test 'device form saves and deletes a policy' device_form_saves_and_deletes
run_test 'device table is rendered with accessible semantics' device_table_is_rendered
run_test 'doctor button writes and displays a report' doctor_button_writes_report
run_test 'rendered AI form contains its action' rendered_ai_form_contains_action
run_test 'failed actions show busy or error instead of success' failed_actions_show_busy_or_error
run_test 'invalid device HTML is not rendered' invalid_device_is_not_rendered
run_test 'public status requires the main rule for success' public_status_requires_rule_for_success
run_test 'TV policy and optional shared Google preset save through the panel' vpn_list_device_and_google_preset
run_test 'busy list apply preserves file and lookup context' list_busy_preserves_context
run_test 'mobile table headers stay in accessibility tree' mobile_headers_stay_in_accessibility_tree
run_test 'mobile device cards do not clip or stick' mobile_device_cards_do_not_clip_or_stick
run_test 'mobile status link keeps its label' mobile_status_link_keeps_its_label
run_test 'admin lookup precedes management and settings' admin_lookup_precedes_management_and_settings
run_test 'public lookup is read-only and hides list contents' public_lookup_is_read_only
run_test 'public lookup summarizes mixed routes and reasons' public_lookup_summarizes_mixed_routes
run_test 'public lookup handles AI block without a device' public_lookup_handles_ai_block_without_device
run_test 'public lookup reports missing DNS addresses' public_lookup_reports_missing_addresses
run_test 'multi-VPN device form saves and renders policy' multi_vpn_device_form_works
run_test 'IPv6 form toggles block on and off' ipv6_form_toggles_block
run_test 'backup button and download are secure' backup_button_and_download_are_secure
run_test 'admin journal highlights and pages retained records' admin_journal_pages
run_test 'public journal pages contain only approved events' public_journal_pages
run_test 'log download requires login and preserves every byte' log_download_returns_retained_file
run_test 'neighbor option populates device form' neighbor_option_populates_device_form
run_test 'traffic cards show formatted bytes' traffic_cards_show_formatted_bytes
[ "$FAILURES" -eq 0 ]
