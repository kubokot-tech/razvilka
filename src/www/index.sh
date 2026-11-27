#!/bin/sh
# Веб-морда razvilka: http://<роутер>:98 (логин/пароль — /opt/razvilka/web.users)
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root
# RZ_TEST_* — только для локальных тестов (под lighttpd окружение пустое, берутся пути роутера)
DIR=${RZ_TEST_DIR:-/opt/razvilka}
FVPN=${RZ_TEST_FVPN:-$DIR/razvilka.sh}
LOG=${RZ_TEST_LOG:-/opt/var/log/razvilka.log}
LISTS=$DIR/lists
DNS=${RZ_TEST_DNS:-127.0.0.1}
DIG=${RZ_TEST_DIG:-dig}
CSRF_TOKEN=$(cat "$DIR/csrf.token" 2>/dev/null)

csrf_deny() {
    printf 'Status: 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\nОбновите страницу панели и повторите действие.\n'
    exit 0
}
csrf_check() {
    [ -n "$CSRF_TOKEN" ] || csrf_deny
    cookie=$(printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' | sed -n 's/^[[:space:]]*razvilka_csrf=\([A-Za-z0-9]*\)[[:space:]]*$/\1/p' | head -1)
    [ "$cookie" = "$CSRF_TOKEN" ] || csrf_deny
    scheme=http; [ "${HTTPS:-}" = on ] && scheme=https
    [ "${HTTP_ORIGIN:-}" = "$scheme://$HTTP_HOST" ] || csrf_deny
}

urldecode() {
    awk 'BEGIN{for(i=0;i<256;i++) h[sprintf("%02x",i)]=sprintf("%c",i)}
    {s=$0; gsub(/\+/," ",s); o="";
     while (match(s,/%[0-9A-Fa-f][0-9A-Fa-f]/)) {o=o substr(s,1,RSTART-1) h[tolower(substr(s,RSTART+1,2))]; s=substr(s,RSTART+3)}
     printf "%s", o s}'
}
param() { printf '%s' "$2" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2- | urldecode; }
# все значения параметра (галочки): по одному на строку
params() { printf '%s' "$2" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | while read -r v; do printf '%s' "$v" | urldecode; echo; done; }
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
fmt_bytes() { awk -v b="$1" 'BEGIN { if (b < 1000) printf "%d B", b; else if (b < 1000000) printf "%.1f КБ", b/1000; else if (b < 1000000000) printf "%.1f МБ", b/1000000; else printf "%.2f ГБ", b/1000000000 }'; }
redirect() { printf 'Status: 303 See Other\r\nLocation: ?msg=%s%s\r\n\r\n' "$1" "${2:+&host=$2#check}"; exit 0; }
do_action() {
    msg=$1; shift
    "$@" >/dev/null 2>&1
    rc=$?
    [ "$rc" = 0 ] && redirect "$msg"
    [ "$rc" = 2 ] && redirect busy
    redirect action_error
}
# запись списка без комментария, в нижнем регистре (AS — в верхнем) — для сравнения
norm() { sed -e 's/#.*//' -e 's/[[:space:]]//g' | tr 'A-Z' 'a-z' | sed 's/^as\([0-9]\)/AS\1/'; }
valid_ipv4() {
    awk -v ip="$1" 'BEGIN {
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
        split(ip,o,"."); for (i=1;i<=4;i++) if (o[i] < 0 || o[i] > 255) exit 1
    }'
}

# ---------- действия (POST) ----------
if [ "$REQUEST_METHOD" = POST ]; then
    csrf_check
    body=$(head -c "${CONTENT_LENGTH:-0}")
    exec </dev/null   # дальше никто не должен читать соединение с браузером
    a=$(param action "$body")
    case "$a" in
        add_entry|save_list|contact)
            exec 9>>"$DIR/.lockf" || redirect action_error
            "${RZ_TEST_FLOCK:-flock}" -n 9 || redirect busy
            # CLI inherits fd 9 with the same pending settings transaction.
            export LOCK_HELD=1
            ;;
    esac
    case "$a" in
        start)        do_action started $FVPN start ;;
        stop)         do_action stopped $FVPN stop ;;
        mode_kill)    do_action mode $FVPN mode kill ;;
        mode_soft)    do_action mode $FVPN mode soft ;;
        mode_direct)  do_action mode $FVPN mode direct ;;
        check)        do_action checked $FVPN watchdog ;;
        update)       do_action updated $FVPN update ;;
        killtest)     do_action killtest $FVPN killtest 3 ;;
        killtest_off) do_action killtest_off $FVPN killtest off ;;
        vpn_restart)  do_action vpn_restart $FVPN vpn-restart ;;
        ai_save)
            if [ "$(param ai_protect "$body")" = 1 ]; then
                do_action ai_on $FVPN ai-on
            else
                do_action ai_off $FVPN ai-off
            fi ;;
        ipv6_save)
            if [ "$(param ipv6_block "$body")" = 1 ]; then
                do_action ipv6_on $FVPN ipv6-block on
            else
                do_action ipv6_off $FVPN ipv6-block off
            fi ;;
        doctor)
            $FVPN doctor > "$DIR/doctor.txt" 2>&1; redirect doctor ;;
        backup)
            archive=$("$FVPN" backup 2>/dev/null); rc=$?
            if [ "$rc" = 0 ]; then
                file=${archive##*/}
                case "$file" in ''|*[!A-Za-z0-9._-]*) redirect action_error ;; esac
                printf 'Status: 303 See Other\r\nLocation: ?msg=backup_done&file=%s\r\n\r\n' "$file"
                exit 0
            fi
            [ "$rc" = 2 ] && redirect busy
            redirect action_error ;;
        device_save)
            ip=$(param ip "$body" | tr -cd '0-9.' | head -c 15)
            neighbor=$(param neighbor "$body" | tr -cd '0-9.' | head -c 15)
            [ -n "$neighbor" ] && ip=$neighbor
            policy=$(param policy "$body")
            case "$policy" in default|direct|vpn|vpn-all) ;; *) redirect device_error ;; esac
            name=$(param name "$body" | tr -d '|\r\n' | head -c 80)
            if [ -z "$name" ] && [ -n "$neighbor" ]; then
                name=$($FVPN neighbors 2>/dev/null | awk -F'|' -v ip="$neighbor" '$1 == ip {print $3; exit}')
            fi
            vpn=$(param vpn "$body"); case "$vpn" in primary|secondary) ;; *) vpn=primary ;; esac
            do_action device_saved $FVPN device-set "$ip" "$policy" "$vpn" "$name" ;;
        device_delete)
            ip=$(param ip "$body" | tr -cd '0-9.' | head -c 15)
            do_action device_deleted $FVPN device-del "$ip" ;;
        add_entry)
            l=$(param list "$body")
            case "$l" in isp) f=$LISTS/direct.list; o=$LISTS/vpn.list ;; vpn) f=$LISTS/vpn.list; o=$LISTS/direct.list ;; *) redirect unknown ;; esac
            back=$(param host "$body" | tr -cd 'A-Za-z0-9.-' | head -c 253)
            e=$(param entry "$body" | norm | head -c 253)
            echo "$e" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^AS[0-9]{1,10}$|^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]*[a-z][a-z0-9-]*$' || redirect badentry "$back"
            moved=
            # из другого списка убираем (перенос), в нужный — дописываем, если ещё нет
            if grep -q . "$o" 2>/dev/null; then
                cp -p "$o" "$o.bak"
                while IFS= read -r line; do [ "$(echo "$line" | norm)" = "$e" ] && moved=1 || printf '%s\n' "$line"; done < "$o.bak" > "$o.new" && mv "$o.new" "$o"
                [ -n "$moved" ] || cp -p "$o.bak" "$o"
            fi
            [ -f "$f" ] || : > "$f"
            have=; while IFS= read -r line; do [ "$(echo "$line" | norm)" = "$e" ] && have=1; done < "$f"
            if [ -z "$have" ]; then
                cp -p "$f" "$f.bak" 2>/dev/null
                printf '%s  # добавлено из проверки %s, %s\n' "$e" "${back:-—}" "$(date +%F)" >> "$f"
            fi
            printf '%s|%s|%s|%s\n' "$e" "$l" "${moved:-}" "${have:-}" > "$DIR/last_add"
            $FVPN lists >/dev/null 2>&1; rc=$?
            [ "$rc" = 0 ] && redirect added "$back"
            [ "$rc" = 2 ] && redirect apply_busy "$back"
            redirect apply_error "$back" ;;
        save_list)
            l=$(param list "$body")
            case "$l" in isp) f=$LISTS/direct.list ;; vpn) f=$LISTS/vpn.list ;; allow) f=$LISTS/kill-allow.list ;; *) redirect unknown ;; esac
            if [ "$l" = allow ]; then   # галочки наборов мягкого kill: только известные ключи
                known=" $($FVPN presets | cut -d'|' -f1 | tr '\n' ' ') "
                params preset "$body" | while read -r k; do case "$known" in *" $k "*) echo "$k" ;; esac; done > "$DIR/kill-allow.presets"
            fi
            [ -f "$f" ] || : > "$f"
            : > "$DIR/last_save.txt"
            param content "$body" | tr -d '\r' | awk -v bad="$DIR/last_save.txt" '
                { line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line); cm="" }
                line == "" { next }
                line ~ /^#/ { print line; next }
                # комментарий в конце строки: «AS57629  # Иви» — проверяем запись, комментарий сохраняем
                { i = index(line, "#"); if (i > 0) { cm = "  " substr(line, i); line = substr(line, 1, i - 1); gsub(/[ \t]+$/, "", line) } }
                { lc=tolower(line); sub(/^https?:\/\//, "", lc); sub(/\/.*$/, "", lc) }
                line ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {
                    split(line, o, /[.\/]/); ok = 1
                    for (i = 1; i <= 4; i++) if (o[i] > 255) ok = 0
                    if (line ~ /\// && (o[5] > 32 || o[5] < 1)) ok = 0
                    if (ok) { if (!seen[line]++) print line cm } else print line > bad
                    next }
                lc ~ /^as[0-9]+$/ { u=toupper(lc); if (!seen[u]++) print u cm; next }
                lc ~ /^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]*[a-z][a-z0-9-]*$/ { if (!seen[lc]++) print lc cm; next }
                { print line > bad }' > "$f.new"
            cp -p "$f" "$f.bak" 2>/dev/null
            mv "$f.new" "$f"
            echo "$l" > "$DIR/last_save_list"
            if [ "$l" = allow ]; then $FVPN allow >/dev/null 2>&1; else $FVPN lists >/dev/null 2>&1; fi
            rc=$?
            [ "$rc" = 0 ] && redirect saved
            [ "$rc" = 2 ] && redirect apply_busy
            redirect apply_error ;;
        contact)
            param contact "$body" | tr -d '\r' | head -c 600 > "$DIR/contact.txt"
            do_action contact $FVPN stub ;;
        *) redirect unknown ;;
    esac
fi

# ---------- страница (GET) ----------
q=$QUERY_STRING
msg=$(param msg "$q")
host=$(param host "$q" | tr -cd 'A-Za-z0-9.-' | head -c 253)

eval "$($FVPN status-kv 2>/dev/null | grep -E '^[a-z][a-z0-9_]*=[A-Za-z0-9 .:/_-]*$' | sed -E "s/^([a-z][a-z0-9_]*)=(.*)$/S_\1='\2'/")"

case "$msg" in
    started) m="Основные правила маршрутизации включены." ;;  stopped) m="Основные правила выключены. Отдельные правила для устройств, AI-сервисов и IPv6 по-прежнему действуют, если вы их включили." ;;
    busy) m="Другая операция ещё выполняется. Повторите через несколько секунд." ;;
    action_error) m="Операция не выполнена. Подробности — в журнале внизу страницы." ;;
    apply_error) m="Изменения сохранены в файле, но применить их не удалось. Проверьте журнал." ;;
    apply_busy) m="Изменения сохранены, но пока не применены: выполняется другая операция. Повторите через несколько секунд." ;;
    mode) m="Настройка на случай сбоя VPN сохранена." ;; checked) m="Проверка выполнена." ;;
    updated) m="Список российских сетей обновлён." ;; killtest) m="Началась трёхминутная проверка блокировки. Её можно остановить досрочно." ;;
    killtest_off) m="Проверка блокировки остановлена." ;; vpn_restart) m="VPN перезапущен." ;;
    contact) m="Контакт для связи обновлён на странице сбоя." ;;
    ai_on) m="Защита известных адресов Claude Code и ChatGPT включена." ;;
    ai_off) m="AI-защита выключена." ;;
    ipv6_on) m="Внешний IPv6 заблокирован." ;;
    ipv6_off) m="Внешний IPv6 разрешён." ;;
    ai_error) m="Не удалось применить AI-защиту. Откройте диагностику и проверьте правила для AI-сервисов." ;;
    doctor) m="Диагностика выполнена." ;;
    backup_done) m="Резервная копия создана." ;;
    device_saved) m="Правило для устройства сохранено и уже действует." ;;
    device_deleted) m="Теперь для устройства действуют общие правила." ;;
    device_error) m="Не удалось сохранить политику устройства. Проверьте IPv4-адрес и журнал." ;;
    added) IFS='|' read -r ae al am ah < "$DIR/last_add" 2>/dev/null
           [ "$al" = isp ] && aln="всегда напрямую" || aln="всегда через VPN"
           [ "$al" = isp ] && oln="всегда через VPN" || oln="всегда напрямую"
           if [ -n "$ah" ]; then m="$ae уже был в списке «$aln»."; else m="$ae добавлен в «$aln» и применён."; fi
           [ -n "$am" ] && m="$m Из списка «$oln» убран." ;;
    badentry) m="Эту запись нельзя добавить в список." ;;
    saved) ln=$(cat "$DIR/last_save_list" 2>/dev/null)
           case "$ln" in isp) lnn="всегда напрямую" ;; vpn) lnn="всегда через VPN" ;; *) lnn="разрешено при падении туннеля" ;; esac
           m="Список «$lnn» сохранён и применён."
           [ -s "$DIR/last_save.txt" ] && m="$m Пропущенные записи: $(tr '\n' ' ' < "$DIR/last_save.txt")" ;;
    *) m= ;;
esac

if [ "$S_enabled" != 1 ]; then st="off"; stt="Основные правила выключены"; std="Роутер использует обычные маршруты. Ручные списки временно отключены."
    [ "$S_ai_active" = 1 ] && std="$std Защита адресов Claude Code и ChatGPT остаётся включённой."
elif [ "$S_killtest" = 1 ]; then st="warn"; stt="Идёт проверка блокировки"; std="Роутер временно применил ограничения на случай сбоя VPN. Проверку можно остановить в разделе «Управление»."
elif [ "$S_tunnel" = 1 ] && [ "$S_rule" = 1 ]; then st="ok"; stt="Основной VPN работает"; std="По общим правилам российские IPv4-адреса доступны напрямую, зарубежные — через VPN."
elif [ "$S_kill" = 1 ]; then st="bad"; stt="Действует блокировка"; std="Роутер ограничил прямой доступ к зарубежным адресам. Доступ через провайдера определяется выбранным режимом и списками исключений."
elif [ "$S_tunnel" != 1 ] && [ "$S_rule" != 1 ]; then st="bad"; stt="Основной VPN недоступен"; std="Основное правило VPN сейчас отключено. Для устройств без отдельных правил роутер использует обычный маршрут провайдера."
    [ "$S_ai_active" = 1 ] && std="$std Для защищённых AI-адресов прямой маршрут через провайдера запрещён."
elif [ "$S_tunnel" != 1 ]; then st="warn"; stt="VPN не отвечает"; std="Неудачных проверок подряд — ${S_fails:-0}. Роутер проверяет связь каждую минуту."
else st="warn"; stt="VPN отвечает, маршрут ещё не включён"; std="Если после следующей проверки маршрут не появится, откройте диагностику."
fi

[ -n "$CSRF_TOKEN" ] && printf 'Set-Cookie: razvilka_csrf=%s; Path=/; HttpOnly; SameSite=Strict\r\n' "$CSRF_TOKEN"
printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'

# иконка статус-карточки (только оформление)
case "$st" in
    ok)   ico='<path d="M5 12.5l4.5 4.5L19 7.5"/>' ;;
    bad)  ico='<path d="M7 7l10 10M17 7L7 17"/>' ;;
    warn) ico='<path d="M12 6v8"/><path d="M12 18v.01"/>' ;;
    *)    ico='<path d="M12 4v8"/><path d="M7 7.5a7 7 0 1 0 10 0"/>' ;;
esac

cat <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Razvilka</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/journal.css">
<style>
:root{
--bg:#f6f3ee;--bg2:#eee9e2;--card:#fff;--fg:#1d1b20;--mut:#67626d;--line:#e6e0d8;
--acc:#5046e5;--acch:#4338ca;--accfg:#fff;--accs:#eceafe;--glow:rgba(99,88,240,.14);
--ok:#16803c;--okb:#e5f5ea;--bad:#c4261d;--badb:#fdeceb;--warn:#a85208;--warnb:#fdf1dc;--off:#5c6270;--offb:#eceef2;
--isp:#0d7a63;--ispb:#e1f4ef;--vpn:#6a48d7;--vpnb:#efeafd;
--sh:0 1px 2px rgba(29,27,32,.04),0 10px 30px -14px rgba(29,27,32,.16);
--r:18px;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace;
color-scheme:light}
@media (prefers-color-scheme:dark){:root{
--bg:#121317;--bg2:#1d2026;--card:#191b20;--fg:#eceaf0;--mut:#a29daa;--line:#2b2e36;
--acc:#a29bff;--acch:#b9b3ff;--accfg:#17153a;--accs:#25233f;--glow:rgba(130,120,255,.16);
--ok:#5fd48d;--okb:#11291b;--bad:#ff8b82;--badb:#341719;--warn:#f6c564;--warnb:#2e2413;--off:#aab0bc;--offb:#23262c;
--isp:#4fd3b5;--ispb:#11302a;--vpn:#b9a4ff;--vpnb:#261f42;
--sh:0 1px 2px rgba(0,0,0,.3),0 10px 30px -14px rgba(0,0,0,.6);
color-scheme:dark}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;min-height:100vh;color:var(--fg);background:var(--bg);
background-image:radial-gradient(900px 420px at 50% -180px,var(--glow),transparent 70%);background-repeat:no-repeat;
font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
main{max-width:880px;margin:0 auto;padding:20px 16px 40px}
a{color:var(--acc);text-underline-offset:3px}
code{font-family:var(--mono);font-size:.88em;background:var(--bg2);border-radius:6px;padding:1px 6px}
svg{flex:none}
.top{display:flex;align-items:center;gap:12px;margin:4px 0 20px}
.logo{flex:none;width:40px;height:40px;filter:drop-shadow(0 6px 14px rgba(80,70,229,.28))}.logo svg{display:block}
.top h1{font-size:19px;line-height:1.2;margin:0;letter-spacing:-.01em}
.top p{margin:2px 0 0;color:var(--mut);font-size:13px}
.top .ref{margin-left:auto;display:inline-flex;align-items:center;gap:6px;min-height:40px;padding:0 12px;border-radius:12px;
color:var(--mut);text-decoration:none;font-size:13.5px;font-weight:600;border:1px solid var(--line);background:var(--card)}
.top .ref:hover{color:var(--fg)}
.msg{display:flex;gap:10px;align-items:flex-start;background:var(--accs);color:var(--fg);border:1px solid var(--line);
border-left:4px solid var(--acc);border-radius:14px;padding:12px 14px;margin-bottom:16px}
.msg svg{color:var(--acc);margin-top:2px}
.hero{--c:var(--off);--cb:var(--offb);position:relative;overflow:hidden;display:flex;gap:18px;align-items:center;
padding:22px;border-radius:24px;margin-bottom:14px;border:1px solid var(--line);box-shadow:var(--sh);
background:linear-gradient(135deg,var(--cb) 0%,var(--cb) 35%,var(--card) 100%)}
.hero.ok{--c:var(--ok);--cb:var(--okb)}.hero.bad{--c:var(--bad);--cb:var(--badb)}
.hero.warn{--c:var(--warn);--cb:var(--warnb)}.hero.off{--c:var(--off);--cb:var(--offb)}
.hero:before{content:"";position:absolute;right:-70px;top:-90px;width:260px;height:260px;border-radius:50%;background:var(--c);opacity:.07}
.hero:after{content:"";position:absolute;right:30px;bottom:-110px;width:180px;height:180px;border-radius:50%;background:var(--c);opacity:.05}
.hero .ico{position:relative;z-index:1;width:68px;height:68px;border-radius:22px;display:grid;place-items:center;
background:var(--c);color:var(--card);box-shadow:0 12px 26px -12px var(--c)}
.hero .txt{position:relative;z-index:1;min-width:0}
.kick{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--c)}
.dot{position:relative;width:9px;height:9px;border-radius:50%;background:var(--c)}
.hero.ok .dot:after,.hero.bad .dot:after,.hero.warn .dot:after{content:"";position:absolute;inset:0;border-radius:50%;
background:var(--c);animation:ping 2.2s cubic-bezier(0,0,.2,1) infinite}
@keyframes ping{0%{transform:scale(1);opacity:.55}80%,100%{transform:scale(3);opacity:0}}
.hero h2{font-size:23px;line-height:1.25;margin:4px 0 4px;letter-spacing:-.015em}
.hero p{margin:0;color:var(--mut)}
.tiles{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-bottom:22px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:13px 14px;box-shadow:var(--sh)}
.tile .k{display:flex;align-items:center;gap:7px;font-size:12.5px;color:var(--mut)}
.tile .k svg{color:var(--acc)}
.tile .v{display:block;margin-top:5px;font-size:15.5px;font-weight:650;line-height:1.3;overflow-wrap:anywhere}
.tile small{display:block;margin-top:3px;font-size:12px;color:var(--mut)}
.led{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;vertical-align:1px;background:var(--off)}
.led.on{background:var(--ok);box-shadow:0 0 0 3px var(--okb)}.led.no{background:var(--bad);box-shadow:0 0 0 3px var(--badb)}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:18px;margin-bottom:14px;box-shadow:var(--sh)}
.card>h2{display:flex;align-items:center;gap:10px;font-size:16px;margin:0 0 14px;letter-spacing:-.01em}
.ch .b{width:30px;height:30px;border-radius:10px;display:grid;place-items:center;background:var(--accs);color:var(--acc)}
.sub{font-size:13px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--mut);margin:20px 0 10px}
.mut{color:var(--mut);font-size:13.5px}
.note{display:flex;gap:10px;font-size:13.5px;color:var(--mut);background:var(--bg);border-radius:12px;padding:11px 13px;margin:12px 0 0}
.note svg{color:var(--acc);margin-top:2px}
form{margin:0}
button,.btn{-webkit-appearance:none;appearance:none;display:inline-flex;align-items:center;justify-content:center;gap:8px;
min-height:44px;padding:10px 16px;border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--fg);
font:inherit;font-weight:600;line-height:1.2;text-align:center;text-decoration:none;cursor:pointer;
transition:background .15s,border-color .15s,box-shadow .15s,transform .05s}
button:hover,.btn:hover{background:var(--bg2)}
button:active,.btn:active{transform:translateY(1px)}
button:focus-visible,.btn:focus-visible,a:focus-visible,input:focus-visible,textarea:focus-visible{outline:3px solid var(--acc);outline-offset:2px}
button.pri{background:var(--acc);border-color:var(--acc);color:var(--accfg);box-shadow:0 6px 16px -8px var(--acc)}
button.pri:hover{background:var(--acch);border-color:var(--acch)}
button.danger{color:var(--bad)}
button.danger:hover{background:var(--badb);border-color:var(--bad)}
.actions{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
.actions button{width:100%}
.seg{display:grid;grid-template-columns:1fr 1fr;gap:4px;padding:4px;border-radius:15px;background:var(--bg2);border:1px solid var(--line)}
.seg button{width:100%;flex-direction:column;gap:1px;border:0;background:transparent;color:var(--mut);border-radius:11px;padding:9px 10px;min-height:52px}
.seg button small{font-weight:500;font-size:12px;opacity:.85}
.seg button:hover{color:var(--fg);background:transparent}
.seg button.sel{background:var(--card);color:var(--fg);box-shadow:0 1px 2px rgba(0,0,0,.08),0 4px 12px -6px rgba(0,0,0,.25)}
.seg button.sel span:before{content:"✓ ";color:var(--acc)}
.inline{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-top:14px}
input,textarea,select{font:inherit;width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--fg);
transition:border-color .15s,box-shadow .15s}
input{min-height:44px}
input:focus,textarea:focus,select:focus{border-color:var(--acc);box-shadow:0 0 0 3px var(--accs);outline:none}
::placeholder{color:var(--mut);opacity:.75}
.row{display:flex;gap:8px}.row input{flex:1;min-width:0}.row button{flex:none}
pre{margin:12px 0 0;padding:12px 14px;border-radius:12px;background:var(--bg);border:1px solid var(--line);
font:12.5px/1.6 var(--mono);white-space:pre-wrap;overflow-wrap:anywhere;overflow-x:auto}
.check pre{border-left:4px solid var(--acc)}
.check>label{display:block;margin:-4px 0 8px}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 10px}
.chips span{font-size:12.5px;color:var(--mut);background:var(--bg);border:1px solid var(--line);border-radius:999px;padding:3px 10px}
.chips b{font-family:var(--mono);font-weight:600;color:var(--fg)}
.lists{display:grid;grid-template-columns:1fr;gap:14px;margin-top:14px}
.list{--lc:var(--isp);--lb:var(--ispb);border:1px solid var(--line);border-top:4px solid var(--lc);border-radius:16px;padding:14px;background:var(--card)}
.list.vpn{--lc:var(--vpn);--lb:var(--vpnb)}
.lh{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.tag{display:inline-flex;align-items:center;gap:7px;font-weight:700;color:var(--lc);background:var(--lb);border-radius:999px;padding:4px 12px 4px 10px}
.tag i{width:8px;height:8px;border-radius:50%;background:var(--lc)}
.fn{font:12px var(--mono);color:var(--mut)}
.list textarea{font:13px/1.6 var(--mono);min-height:220px;resize:vertical}
.list textarea:focus{border-color:var(--lc)}
.list button{width:100%;margin-top:10px}
footer{text-align:center;color:var(--mut);font-size:12.5px;margin-top:22px}
@media (min-width:640px){
main{padding:28px 24px 48px}
.tiles{grid-template-columns:repeat(3,minmax(0,1fr))}
.actions{grid-template-columns:repeat(4,minmax(0,1fr))}
.lists{grid-template-columns:1fr 1fr}
.card{padding:22px}
.hero{padding:26px 28px;gap:22px}
.hero h2{font-size:26px}
}
@media (max-width:639px){
.top{display:grid;grid-template-columns:auto 1fr auto auto;gap:8px}
.top .logo{grid-area:1/1}
.top .brand{display:contents}
.top h1{grid-column:2;grid-row:1}
.top p{grid-column:1/-1;grid-row:2}
.top .ref{grid-row:1;margin-left:0}
}
@media (max-width:380px){.hero{flex-direction:column;align-items:flex-start}.top .refresh span{display:none}}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
.res{margin-top:14px;display:grid;gap:10px}
.rsum{margin:0;font-size:16px}.rsum .tv{color:var(--vpn)}.rsum .ti{color:var(--isp)}
.rdom{margin:0;font-size:14px}
.ipr{border:1px solid var(--line);border-radius:14px;padding:12px 14px;background:var(--bg)}
.iph{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.iph code{font:600 14px/1.4 var(--mono)}
.bdg{font-size:12.5px;font-weight:700;border-radius:999px;padding:3px 10px}
.bdg.vpn{color:var(--vpn);background:var(--vpnb)}.bdg.isp{color:var(--isp);background:var(--ispb)}.bdg.loc{color:var(--off);background:var(--offb)}
.why{font-size:14px;margin:6px 0 8px}
.chips2{display:flex;flex-wrap:wrap;gap:6px}
.chip{display:inline-block;font-size:12.5px;border-radius:999px;padding:3px 10px;border:1px solid var(--line);background:var(--card);overflow-wrap:anywhere}
.chip.isp{color:var(--isp);background:var(--ispb);border-color:transparent;font-weight:600}
.chip.vpn{color:var(--vpn);background:var(--vpnb);border-color:transparent;font-weight:600}
.chip.mut{color:var(--mut)}
.addmsg{margin-top:12px;padding:10px 14px;border-radius:12px;background:var(--accs);color:var(--fg);font-size:14px;font-weight:600}
.adds{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}.addf{display:inline}
.mini{font:600 12.5px/1.2 inherit;min-height:32px;padding:6px 12px;border-radius:999px;cursor:pointer;border:1px solid transparent}
.mini.isp{color:var(--isp);background:var(--ispb)}.mini.vpn{color:var(--vpn);background:var(--vpnb)}
.mini:hover{filter:brightness(.96)}.mini:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
.addd{margin-top:8px}.addd summary{cursor:pointer;font-size:13px;color:var(--acc);font-weight:600;list-style:none}
.addd summary::-webkit-details-marker{display:none}.addd summary::before{content:"+ "}.addd[open] summary::before{content:"− "}
.seg3{grid-template-columns:repeat(3,1fr)}@media (max-width:560px){.seg3{grid-template-columns:1fr}}
.checks{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:8px;margin-top:8px}
.chk{display:flex;gap:10px;align-items:flex-start;border:1px solid var(--line);border-radius:12px;padding:10px 12px;background:var(--card);cursor:pointer}
.chk input{margin-top:3px;width:18px;height:18px;accent-color:var(--acc);flex:none}
.chk b{display:block;font-size:14px}.chk small{display:block;color:var(--mut);font-size:12px;overflow-wrap:anywhere}
.table-container{container-type:inline-size}
.table-wrapper{overflow:auto;max-inline-size:100%;max-block-size:min(500px,80vh)}
.table-wrapper table{width:100%;border-collapse:separate;border-spacing:0;--label-2:"IPv4";--label-3:"Политика";--label-4:"VPN";--label-5:"Действия"}
.table-wrapper thead{position:sticky;inset-block-start:0;z-index:1;background:var(--card)}
.table-wrapper th,.table-wrapper td{padding:10px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}
.table-wrapper thead th{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.table-wrapper tbody th{position:sticky;inset-inline-start:0;background:var(--card);min-width:160px}
.table-wrapper .actions-cell{display:flex;gap:6px;flex-wrap:wrap}
.table-wrapper .actions-cell button{white-space:nowrap}
.device-add{display:grid;gap:10px;margin-top:18px}.device-add label{font-size:13px;font-weight:600}
.device-add input,.device-add select{margin-top:5px}
@container (width < 600px){
.table-wrapper{max-block-size:none;overflow:visible}
.table-wrapper table,.table-wrapper thead,.table-wrapper tbody,.table-wrapper tr,.table-wrapper th,.table-wrapper td{display:block}
.table-wrapper thead{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap;border:0}.table-wrapper tr{margin-block-end:16px;border:1px solid var(--line);border-radius:12px;overflow:hidden}
.table-wrapper tbody th{position:static;background:var(--bg2);min-width:0}
.table-wrapper td:nth-child(2)::before{content:var(--label-2) ": ";font-weight:600}
.table-wrapper td:nth-child(3)::before{content:var(--label-3) ": ";display:block;font-weight:600;margin-bottom:5px}
.table-wrapper td:nth-child(4)::before{content:var(--label-4) ": ";display:block;font-weight:600;margin-bottom:5px}
.table-wrapper td:nth-child(5)::before{content:var(--label-5) ": ";display:block;font-weight:600;margin-bottom:5px}
}
@media (min-width:640px){.device-add{grid-template-columns:repeat(2,minmax(0,1fr));align-items:end}}
@media (min-width:1000px){.device-add{grid-template-columns:repeat(3,minmax(0,1fr))}}
</style></head><body><main>
<header class="top">
<div class="logo" aria-hidden="true"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="40" height="40" aria-hidden="true" focusable="false"><defs><linearGradient id="rzv-mark-bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6359f0"/><stop offset="1" stop-color="#3a2fc2"/></linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#rzv-mark-bg)"/><g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="6"><path d="M32 39 C32 29 19 28 19 15 M12.5 20.5 L19 14 L25.5 20.5" stroke="#4fd3b5"/><path d="M32 39 C32 29 45 28 45 15 M38.5 20.5 L45 14 L51.5 20.5" stroke="#cbbcff"/><path d="M32 53 V39" stroke="#fff"/></g><circle cx="32" cy="39" r="5.5" fill="#fff"/></svg></div>
<div class="brand"><h1>Razvilka</h1><p><strong>Развилка для трафика на роутерах Keenetic и Netcraze:</strong> российское — напрямую, иностранное — через VPN.</p></div>
<a class="ref refresh" href="?"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/></svg><span>Обновить</span></a>
<a class="ref" href="/status" title="Страница статуса без пароля"><span>Статус</span></a>
</header>
EOF
[ -n "$m" ] && printf '<div class="msg" role="status"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.01"/></svg><div>%s</div></div>\n' "$(printf '%s' "$m" | esc)"
cat <<EOF
<section class="hero $st" aria-live="polite">
<div class="ico" aria-hidden="true"><svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">$ico</svg></div>
<div class="txt"><div class="kick"><span class="dot"></span>Состояние</div><h2>$stt</h2><p>$std</p></div>
</section>

<div class="tiles">
<div class="tile"><span class="k">VPN-туннель</span><span class="v"><i class="led $([ "$S_tunnel" = 1 ] && echo on || echo no)"></i>$([ "$S_tunnel" = 1 ] && echo "отвечает" || echo "не отвечает")</span>${S_vpn_ip:+<small>$S_vpn_ip</small>}</div>
<div class="tile"><span class="k">Дополнительный VPN</span><span class="v">${S_vpn2_if:-не настроен}</span><small>$([ -z "$S_vpn2_if" ] && echo "задаётся при установке или обновлении" || { [ "$S_vpn2_tunnel" = 1 ] && echo "отвечает" || echo "не отвечает"; })</small></div>
<div class="tile"><span class="k">При сбое VPN</span><span class="v">$([ "$S_failmode" = kill ] && echo "блокировка" || { [ "$S_failmode" = soft ] && echo "с исключениями" || echo "напрямую"; })</span></div>
<div class="tile"><span class="k">Сети РФ напрямую</span><span class="v">${S_ru:-0}</span><small>обновление · ${S_ru_date:-—}</small></div>
<div class="tile"><span class="k">Адрес VPN-сервера</span><span class="v">${S_servers:-—}</span></div>
<div class="tile"><span class="k">Ручные списки</span><span class="v">${S_direct_n:-0} напрямую · ${S_vpn_n:-0} через VPN</span></div>
<div class="tile"><span class="k">AI-защита</span><span class="v">$(if [ "$S_ai_protect" != 1 ]; then echo "выключена"; elif [ "$S_ai_active" = 1 ]; then echo "включена · ${S_ai_routes:-0} адресов"; else echo "ошибка применения"; fi)</span>$([ "${S_ai_failed:-0}" -gt 0 ] && echo "<small>Без ответа DNS — $S_ai_failed. Роутер сохранил прежние адреса.</small>")</div>
<div class="tile"><span class="k">Отдельные устройства</span><span class="v">${S_devices_n:-0}</span>$([ "${S_devices_n:-0}" -gt 0 ] && { [ "$S_devices_active" = 1 ] && echo '<small>индивидуальные правила применены</small>' || echo '<small>проверьте правила в диагностике</small>'; })</div>
<div class="tile"><span class="k">Внешний IPv6</span><span class="v">$([ "$S_ipv6_blocked" = 1 ] && echo "заблокирован" || echo "разрешён")</span></div>
<div class="tile"><span class="k">Выход к провайдеру</span><span class="v">${S_gw:-${S_wan_dev:-—}}</span>$([ -z "$S_gw" ] && [ -n "$S_wan_dev" ] && echo '<small>маршрут без шлюза</small>')</div>
</div>

<section class="card check" id="check">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg></span>Проверка маршрута</h2>
<label class="mut" for="lookup-host">Домен или IPv4-адрес</label>
<form method="get" class="row"><input id="lookup-host" name="host" placeholder="kion.ru или 1.2.3.4" value="$host" autocapitalize="off" autocorrect="off" spellcheck="false"><button class="pri">Проверить</button></form>
EOF
if [ -n "$host" ]; then
    # dig, а не nslookup: busybox nslookup дописывает после IP имя из PTR-записи
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then ips=$host; isip=1; elif [ "${host#-}" != "$host" ]; then ips=; isip=; else
    ips=$("$DIG" +short +time=3 +tries=1 "$host" A @$DNS 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | sort -u); isip=; fi
    case "$msg" in added|badentry) printf '<div class="addmsg">%s</div>\n' "$(printf '%s' "$m" | esc)" ;; esac
    echo '<div class="res">'
    if [ -z "$ips" ]; then
        echo "<p class=\"rsum\">Не удалось найти адрес <b>$host</b></p>"
    else
        # сам домен записан в списках?
        if [ -z "$isip" ]; then
            inl=
            for l in direct vpn; do
                f=$LISTS/$l.list
                sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" 2>/dev/null | grep -qixF "$host" && inl="$inl $l"
            done
        fi
        # кнопка «добавить запись в список» (POST, после — назад к этой же проверке)
        addbtn() { printf '<form method="post" class="addf"><input type="hidden" name="action" value="add_entry"><input type="hidden" name="list" value="%s"><input type="hidden" name="entry" value="%s"><input type="hidden" name="host" value="%s"><button class="mini %s">%s</button></form>' "$1" "$2" "$host" "$1" "$3"; }
        rows=; nv=0; nd=0; nb=0; nu=0; nl=0
        for ip in $ips; do
            lk=$($FVPN lookup "$ip" "${REMOTE_ADDR:-}" 2>/dev/null)
            g() { echo "$lk" | sed -n "s/^$1=//p"; }
            dev=$(g dev | head -1); tbl=$(g table | head -1); ai=$(g ai | head -1); blocked=$(g blocked | head -1)
            md=$(g match_direct | tr '\n' ' '); mv=$(g match_vpn | tr '\n' ' ')
            if [ "$ai" = 1 ] && [ "$blocked" = 1 ]; then nb=$((nb+1)); badge='<span class="bdg loc">заблокировано</span>'
            elif [ "$blocked" = 1 ]; then nb=$((nb+1)); badge='<span class="bdg loc">заблокировано</span>'
            elif [ -z "$dev" ]; then nu=$((nu+1)); badge='<span class="bdg loc">маршрут неизвестен</span>'
            elif [ "$dev" = "$S_vpn_if" ] || [ "$dev" = "$S_vpn2_if" ]; then nv=$((nv+1)); badge='<span class="bdg vpn">через VPN</span>'
            elif echo "$dev" | grep -q '^br'; then nl=$((nl+1)); badge='<span class="bdg loc">локальная сеть</span>'
            else nd=$((nd+1)); badge='<span class="bdg isp">напрямую</span>'; fi
            if [ "$ai" = 1 ] && [ "$blocked" = 1 ]; then why="Для этого устройства прямой доступ закрыт. Адрес входит в список защиты Claude Code и ChatGPT."
            elif [ "$blocked" = 1 ]; then why="Маршрутизация запрещает выход с этого устройства"
            elif [ -z "$dev" ]; then why="Не удалось определить маршрут"
            else case "$tbl:$dev" in
                1030:*)           why="индивидуальная политика устройства: напрямую" ;;
                103*:"$S_vpn_if"|103*:"$S_vpn2_if") why="индивидуальная политика устройства: через VPN" ;;
                1019:"$S_vpn_if") why="AI-защита: только через VPN" ;;
                1020:"$S_vpn_if") why="ручной список «через VPN»" ;;
                1020:*)           why="ручной список «напрямую»" ;;
                *:"$S_vpn_if")    why="основной маршрут через VPN" ;;
                1022:*)           why="прямой маршрут в основной таблице" ;;
                *:br*)            why="адрес домашней сети" ;;
                *)                why="обычная маршрутизация роутера" ;;
            esac; fi
            chips=
            for e in $md; do chips="$chips<span class=\"chip isp\">в «напрямую»: $(echo "$e" | esc)</span>"; done
            for e in $mv; do chips="$chips<span class=\"chip vpn\">в «через VPN»: $(echo "$e" | esc)</span>"; done
            [ -n "$md" ] && [ -n "$mv" ] && chips="$chips<span class=\"chip mut\">совпадения в обоих списках</span>"
            [ "$ai" = 1 ] && chips="$chips<span class=\"chip vpn\">адрес в списке AI-защиты</span>"
            [ "$(g ru)" = 1 ] && chips="$chips<span class=\"chip mut\">сеть РФ</span>" || chips="$chips<span class=\"chip mut\">зарубежная сеть</span>"
            as=$(g asn); [ -n "$as" ] && chips="$chips<span class=\"chip mut\">AS$as $(g holder | esc)</span>"
            adds="$(addbtn isp "$ip" "IP $ip → напрямую")$(addbtn vpn "$ip" "IP $ip → через VPN")"
            [ -n "$as" ] && adds="$adds$(addbtn isp "AS$as" "вся AS$as → напрямую")$(addbtn vpn "AS$as" "вся AS$as → через VPN")"
            rows="$rows<div class=\"ipr\"><div class=\"iph\"><code>$ip</code>$badge</div><div class=\"why\">$why</div><div class=\"chips2\">$chips</div><details class=\"addd\"><summary>Добавить в список</summary><div class=\"adds\">$adds</div></details></div>"
        done
        parts=
        [ "$nv" -eq 0 ] || parts="$parts, $nv через VPN"
        [ "$nd" -eq 0 ] || parts="$parts, $nd напрямую"
        [ "$nl" -eq 0 ] || parts="$parts, $nl в локальной сети"
        [ "$nb" -eq 0 ] || parts="$parts, заблокировано — $nb"
        [ "$nu" -eq 0 ] || parts="$parts, маршрут неизвестен — $nu"
        echo "<p class=\"rsum\"><b>$host</b> · ${parts#, }</p>"
        if [ -z "$isip" ]; then
            case "$inl" in
                *direct*vpn*) echo '<p class="rdom">Домен записан в обоих списках — действует «напрямую».</p>' ;;
                *direct*) echo '<p class="rdom">Домен записан в списке <span class="chip isp">напрямую</span></p>' ;;
                *vpn*)    echo '<p class="rdom">Домен записан в списке <span class="chip vpn">через VPN</span></p>' ;;
                *)        echo '<p class="rdom mut">Для этого домена нет отдельной записи.</p>' ;;
            esac
            echo "<div class=\"adds\">"
            case "$inl" in *direct*) ;; *) addbtn isp "$host" "$host → всегда напрямую" ;; esac
            case "$inl" in *vpn*) ;; *) addbtn vpn "$host" "$host → всегда через VPN" ;; esac
            echo "</div>"
        fi
        echo "$rows"
    fi
    echo '</div>'
fi
cat <<EOF
<p class="mut" style="margin:12px 0 0">Проверка учитывает правила устройства, с которого открыта панель.</p>
</section>

<section class="card">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg></span>Управление</h2>
<div class="actions">
$(if [ "$S_enabled" = 1 ]; then echo '<form method="post"><button class="danger" name="action" value="stop">Отключить основные правила</button></form>'; else echo '<form method="post"><button class="pri" name="action" value="start">Включить основные правила</button></form>'; fi)
<form method="post"><button name="action" value="check">Проверить соединение</button></form>
<form method="post"><button class="danger" name="action" value="vpn_restart">Перезапустить VPN</button></form>
<form method="post"><button name="action" value="update">Обновить список сетей РФ</button></form>
<form method="post"><button name="action" value="doctor">Диагностика</button></form>
<a class="btn" href="#journal">Журнал</a>
<form method="post"><button name="action" value="backup">Создать резервную копию</button></form>
</div>

<div class="sub">При сбое основного VPN</div>
<p class="mut" style="margin:-4px 0 10px">Во время работы роутер переключается после двух неудачных проверок подряд. При запуске без VPN блокировка действует сразу, если она выбрана.</p>
<div class="seg seg3" role="group" aria-label="Режим при сбое VPN">
<form method="post"><button class="$([ "$S_failmode" = direct ] && echo sel)" aria-pressed="$([ "$S_failmode" = direct ] && echo true || echo false)" name="action" value="mode_direct"><span>Через провайдера</span><small>разрешить прямой доступ</small></button></form>
<form method="post"><button class="$([ "$S_failmode" = soft ] && echo sel)" aria-pressed="$([ "$S_failmode" = soft ] && echo true || echo false)" name="action" value="mode_soft"><span>С исключениями</span><small>разрешить выбранные сети</small></button></form>
<form method="post"><button class="$([ "$S_failmode" = kill ] && echo sel)" aria-pressed="$([ "$S_failmode" = kill ] && echo true || echo false)" name="action" value="mode_kill"><span>Блокировать</span><small>закрыть зарубежные адреса</small></button></form>
</div>
<div class="note"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.01"/></svg>
<span>Эта настройка относится к зарубежным адресам, для которых нет отдельного правила. Российские сети из загруженного списка остаются доступны через провайдера. В режиме «С исключениями» можно также разрешить сети, откуда сайты загружают шрифты, скрипты или капчу.</span></div>
<form method="post" action="?" aria-labelledby="ipv6-title">
<input type="hidden" name="action" value="ipv6_save">
<div class="sub" id="ipv6-title">Внешний IPv6</div>
<label class="chk" for="ipv6-block"><input id="ipv6-block" type="checkbox" switch name="ipv6_block" value="1" aria-describedby="ipv6-help"$([ "$S_ipv6_blocked" = 1 ] && echo ' checked')><span><b>Блокировать внешний IPv6</b><small>Для устройств домашней сети</small></span></label>
<p class="mut" id="ipv6-help">При включённой блокировке устройства выходят в интернет по IPv4. Сайты, у которых есть только IPv6-адрес, станут недоступны. Локальная связь по IPv6 и служебные сообщения ICMPv6 сохранятся.</p>
<div class="inline"><button class="pri" type="submit">Сохранить настройку IPv6</button></div>
</form>
<form method="post" action="?" aria-labelledby="ai-title">
<input type="hidden" name="action" value="ai_save">
<div class="sub" id="ai-title">Защита Claude Code и ChatGPT</div>
<label class="chk" for="ai-protect"><input id="ai-protect" type="checkbox" name="ai_protect" value="1" aria-describedby="ai-help"$([ "$S_ai_protect" = 1 ] && echo ' checked')><span><b>Подключаться к AI-сервисам только через VPN</b><small>Для известных IPv4-адресов Claude Code и ChatGPT</small></span></label>
<p class="mut" id="ai-help">Если туннель исчезнет, соединения с адресами из списка будут заблокированы. Список обновляется каждый час. Другие сайты на том же IP тоже попадут под правило. Правила отдельных устройств имеют приоритет. Для IPv6 используйте настройку выше.</p>
<div class="inline"><button class="pri" type="submit">Сохранить настройку AI-защиты</button>$([ "$S_ai_protect" = 1 ] && echo "<span class=\"mut\">защищено адресов и подсетей: ${S_ai_routes:-0}</span>")</div>
</form>
$(if [ "$S_failmode" = soft ]; then
  echo '<form method="post" class="allow"><input type="hidden" name="action" value="save_list"><input type="hidden" name="list" value="allow">'
  echo '<div class="sub" style="margin-top:14px">Исключения при сбое VPN</div><div class="checks">'
  $FVPN presets 2>/dev/null | while IFS='|' read -r k c n e; do
    printf '<label class="chk"><input type="checkbox" name="preset" value="%s"%s><span><b>%s</b><small>%s</small></span></label>\n' "$k" "$([ "$c" = 1 ] && echo ' checked')" "$(printf '%s' "$n" | esc)" "$(printf '%s' "$e" | esc)"
  done
  echo '</div><label class="mut" for="allow-own" style="display:block;margin:12px 0 6px">Свои исключения (домен, IPv4, подсеть или AS). По одной записи на строку.</label>'
  printf '<textarea id="allow-own" name="content" rows="4" spellcheck="false" autocapitalize="off" placeholder="например: static.example.com или AS12345">%s</textarea>\n' "$(cat "$LISTS/kill-allow.list" 2>/dev/null | esc)"
  echo "<div class=\"inline\" style=\"margin-top:10px\"><button class=\"pri\">Сохранить</button><span class=\"mut\">сейчас разрешено: ${S_allow_n:-0} адресов и подсетей</span></div></form>"
fi)
<div class="inline">
$(if [ "$S_killtest" = 1 ]; then echo '<form method="post"><button class="pri" name="action" value="killtest_off">Остановить тест</button></form>'; elif [ "$S_enabled" = 1 ]; then echo '<form method="post"><button name="action" value="killtest">Проверить блокировку на 3 минуты</button></form>'; fi)
</div>
</section>
$(if [ "$msg" = doctor ]; then printf '<section class="card"><h2>Диагностика</h2><pre>%s</pre></section>' "$(cat "$DIR/doctor.txt" 2>/dev/null | esc)"; fi)
$(if [ "$msg" = backup_done ]; then f=$(param file "$q" | tr -cd 'A-Za-z0-9._-'); [ -n "$f" ] && printf '<section class="card"><h2>Резервная копия</h2><p class="mut">В архиве есть пароль панели и настройки сети. Храните копию там, где только у вас есть доступ.</p><a class="btn" href="/backup?f=%s">Скачать архив</a></section>' "$f"; fi)

<section class="card" id="devices">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/></svg></span><span id="devices-title">Отдельные устройства</span></h2>
<p class="mut">Правило привязано к IPv4 устройства и имеет приоритет перед ручными списками и AI-защитой. Закрепите адрес устройства в настройках DHCP роутера. Если выбранный VPN недоступен, соединения, которым нужен этот туннель, блокируются.</p>
<div class="table-container">
<div class="table-wrapper" tabindex="0" role="region" aria-labelledby="devices-title">
<table><thead><tr><th id="dev-col-name">Устройство</th><th id="dev-col-ip">IPv4</th><th id="dev-col-policy">Политика</th><th id="dev-col-vpn">VPN</th><th id="dev-col-actions">Действия</th></tr></thead><tbody>
$(
if [ -f "$DIR/devices.conf" ]; then
    while IFS='|' read -r dip dpo f3 f4 f5; do
        if [ "$dpo" != direct ] && [ "$dpo" != vpn ] && [ "$dpo" != vpn-all ]; then continue; fi
        valid_ipv4 "$dip" || continue
        if [ "$f3" = primary ] || [ "$f3" = secondary ]; then
            dvpn=$f3
            if { [ "$f4" = 0 ] || [ "$f4" = 1 ]; } && [ -n "$f5" ]; then dn=$f5; else dn=$f4; fi
        else dvpn=primary; dn=$f3; fi
        dkey=$(printf '%s' "$dip" | tr '.-' '__'); de=$(printf '%s' "$dip" | esc); dnesc=$(printf '%s' "$dn" | esc)
        printf '<tr><th scope="row" headers="dev-col-name"><form id="dev-%s" method="post" action="?"><input type="hidden" name="ip" value="%s"></form><input form="dev-%s" name="name" maxlength="80" value="%s" aria-label="Название устройства %s"></th>' "$dkey" "$de" "$dkey" "$dnesc" "$dnesc"
        printf '<td headers="dev-col-ip"><code>%s</code></td><td headers="dev-col-policy"><select form="dev-%s" name="policy" aria-label="Политика для %s">' "$de" "$dkey" "$dnesc"
        printf '<option value="default"%s>Как для всех</option><option value="direct"%s>Всегда напрямую</option><option value="vpn"%s>Зарубежное через VPN</option><option value="vpn-all"%s>Весь трафик через VPN</option></select></td>' \
            "$([ "$dpo" = default ] && echo ' selected')" "$([ "$dpo" = direct ] && echo ' selected')" "$([ "$dpo" = vpn ] && echo ' selected')" "$([ "$dpo" = vpn-all ] && echo ' selected')"
        printf '<td headers="dev-col-vpn"><select form="dev-%s" name="vpn" aria-label="VPN для %s"><option value="primary"%s>Основной: %s</option><option value="secondary"%s%s>Дополнительный: %s</option></select></td>' \
            "$dkey" "$dnesc" "$([ "$dvpn" = primary ] && echo ' selected')" "$S_vpn_if" "$([ "$dvpn" = secondary ] && echo ' selected')" "$([ -z "$S_vpn2_if" ] && echo ' disabled')" "${S_vpn2_if:-не настроен}"
        printf '<td headers="dev-col-actions"><div class="actions-cell"><button form="dev-%s" type="submit" name="action" value="device_save">Сохранить</button><button form="dev-%s" class="danger" type="submit" name="action" value="device_delete">Удалить</button></div></td></tr>' "$dkey" "$dkey"
    done < "$DIR/devices.conf"
fi
)
</tbody></table></div></div>
<form method="post" action="?" class="device-add" aria-label="Добавить устройство">
<input type="hidden" name="action" value="device_save">
$(if [ -n "$($FVPN neighbors 2>/dev/null)" ]; then
    echo '<label for="device-neighbor">Подключённое устройство</label><select id="device-neighbor" name="neighbor"><option value="">Выберите из списка</option>'
    $FVPN neighbors 2>/dev/null | while IFS='|' read -r nip nmac nname nsrc; do
        printf '<option value="%s">%s — %s (%s)</option>\n' "$(printf '%s' "$nip" | esc)" "$(printf '%s' "$nip" | esc)" "$(printf '%s' "${nname:-без имени}" | esc)" "$(printf '%s' "$nmac" | esc)"
    done
    echo '</select>'
fi)
<label>Название<input name="name" maxlength="80" placeholder="Рабочий ноутбук"></label>
<label>IPv4-адрес вручную<input name="ip" inputmode="decimal" pattern="[0-9.]{7,15}" maxlength="15" placeholder="192.168.1.50"></label>
<label>Политика<select name="policy"><option value="vpn">Зарубежное через VPN</option><option value="vpn-all">Весь трафик через VPN</option><option value="direct">Всегда напрямую</option></select></label>
<label>VPN<select name="vpn"><option value="primary">Основной: $S_vpn_if</option><option value="secondary"$([ -z "$S_vpn2_if" ] && echo ' disabled')>Дополнительный: ${S_vpn2_if:-не настроен}</option></select></label>
<button class="pri" type="submit">Добавить устройство</button>
</form>
</section>

<article class="card" id="traffic">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 17h16M7 12h10M10 7h4M13 2h2M13 22h2"/></svg></span>Трафик интерфейсов</h2>
<div class="tiles">
<div class="tile"><span class="k">$S_vpn_if · RX</span><span class="v">$(fmt_bytes "${S_vpn_rx_bytes:-0}")</span><small>получено через основной VPN</small></div>
<div class="tile"><span class="k">$S_vpn_if · TX</span><span class="v">$(fmt_bytes "${S_vpn_tx_bytes:-0}")</span><small>отправлено через основной VPN</small></div>
<div class="tile"><span class="k">$S_isp_if · RX</span><span class="v">$(fmt_bytes "${S_isp_rx_bytes:-0}")</span><small>получено через провайдера</small></div>
<div class="tile"><span class="k">$S_isp_if · TX</span><span class="v">$(fmt_bytes "${S_isp_tx_bytes:-0}")</span><small>отправлено через провайдера</small></div>
</div>
<p class="mut">Объём данных с момента запуска каждого интерфейса. При аппаратном ускорении часть трафика может не попасть в счётчики.</p>
</article>

<section class="card">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6h11M9 12h11M9 18h11"/><path d="M4.5 6h.01M4.5 12h.01M4.5 18h.01"/></svg></span>Ручные списки</h2>
<div class="chips"><span>домен <b>kion.ru</b></span><span>IP <b>1.2.3.4</b></span><span>подсеть <b>5.6.0.0/16</b></span><span>автономная система <b>AS13238</b></span><span><b>#</b> комментарий</span></div>
<p class="mut" style="margin:0">По одной записи на строку. Поддомены — отдельно (<code>www.kion.ru</code>), русские домены — в punycode (<code>xn--...</code>).
Роутер запрашивает IPv4-адреса доменов при сохранении и затем каждый час. Подсети автономных систем обновляются по данным RIPEstat. Правила устройств и AI-защиты имеют приоритет.</p>
<div class="lists">
<form method="post" class="list isp"><input type="hidden" name="action" value="save_list"><input type="hidden" name="list" value="isp">
<div class="lh"><label class="tag" for="l-isp"><i></i>Всегда напрямую</label><span class="fn">direct.list</span></div>
<textarea id="l-isp" name="content" rows="10" spellcheck="false" autocapitalize="off">$(cat "$LISTS/direct.list" 2>/dev/null | esc)</textarea>
<button class="pri">Сохранить и применить</button></form>
<form method="post" class="list vpn"><input type="hidden" name="action" value="save_list"><input type="hidden" name="list" value="vpn">
<div class="lh"><label class="tag" for="l-vpn"><i></i>Всегда через VPN</label><span class="fn">vpn.list</span></div>
<textarea id="l-vpn" name="content" rows="10" spellcheck="false" autocapitalize="off">$(cat "$LISTS/vpn.list" 2>/dev/null | esc)</textarea>
<button class="pri">Сохранить и применить</button></form>
</div>
<p class="mut" style="margin:12px 0 0">Предыдущая версия каждого файла сохраняется рядом как <code>.bak</code>.</p>
</section>

<section class="card" id="journal" aria-labelledby="journal-title">
<div class="journal-head"><h2 id="journal-title">Журнал</h2>
$([ -f "$LOG" ] && [ ! -L "$LOG" ] && [ -r "$LOG" ] && echo '<a class="btn" href="/log/download" download="razvilka.log">Скачать журнал</a>')
</div>
EOF
log_source=/dev/null
[ -f "$LOG" ] && [ ! -L "$LOG" ] && log_source=$LOG
awk -v cursor="$(param log_end "$q")" -f "$DIR/journal.awk" "$log_source" || echo '<p class="journal-empty">Не удалось прочитать журнал.</p>'
cat <<EOF
</section>
<footer>Скрипт: <code>/opt/razvilka/razvilka.sh</code> · настройки: <code>/opt/razvilka/razvilka.conf</code></footer>
</main></body></html>
EOF
