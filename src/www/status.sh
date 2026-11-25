#!/bin/sh
# Страница статуса Razvilka: http://<роутер>:98/status — без пароля, только чтение; lookup через GET.
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root
DIR=${RZ_TEST_DIR:-/opt/razvilka}
FVPN=${RZ_TEST_FVPN:-$DIR/razvilka.sh}
LOG=${RZ_TEST_LOG:-/opt/var/log/razvilka.log}
DNS=${RZ_TEST_DNS:-127.0.0.1}
DIG=${RZ_TEST_DIG:-dig}

urldecode() {
    awk 'BEGIN{for(i=0;i<256;i++) h[sprintf("%02x",i)]=sprintf("%c",i)}
    {s=$0; gsub(/\+/," ",s); o="";
     while (match(s,/%[0-9A-Fa-f][0-9A-Fa-f]/)) {o=o substr(s,1,RSTART-1) h[tolower(substr(s,RSTART+1,2))]; s=substr(s,RSTART+3)}
     printf "%s", o s}'
}
param() { printf '%s' "$2" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2- | urldecode; }
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
fmt_bytes() { awk -v b="$1" 'BEGIN { if (b < 1000) printf "%d B", b; else if (b < 1000000) printf "%.1f КБ", b/1000; else if (b < 1000000000) printf "%.1f МБ", b/1000000; else printf "%.2f ГБ", b/1000000000 }'; }
host=$(param host "${QUERY_STRING:-}" | tr -cd 'A-Za-z0-9.-' | head -c 253)
eval "$($FVPN status-kv 2>/dev/null | grep -E '^[a-z][a-z0-9_]*=[A-Za-z0-9 .:/_-]*$' | sed -E "s/^([a-z][a-z0-9_]*)=(.*)$/S_\1='\2'/")"

# «3 ч 22 мин», «5 мин», «2 дн 3 ч»
dur() {
    t=$1; [ -z "$t" ] || [ "$t" -lt 0 ] 2>/dev/null && { echo ""; return; }
    d=$((t/86400)); h=$((t%86400/3600)); m=$((t%3600/60))
    if [ $d -gt 0 ]; then echo "$d дн $h ч"; elif [ $h -gt 0 ]; then echo "$h ч $m мин"; elif [ $m -gt 0 ]; then echo "$m мин"; else echo "меньше минуты"; fi
}
when() { [ -n "$1" ] && date -d "@$1" '+%d.%m в %H:%M' 2>/dev/null; }

now=${S_now:-$(date +%s)}
since=""; ago=""
if [ -n "$S_tunnel_since" ] && [ "$S_tunnel_since" -le "$now" ] 2>/dev/null; then
    since=$(when "$S_tunnel_since"); ago=$(dur $((now - S_tunnel_since)))
fi
checked=""; [ -n "$S_last_check" ] && checked=$(dur $((now - S_last_check)))

case "$S_failmode" in soft) mode="блокировать с исключениями" ;; kill) mode="блокировать зарубежные адреса" ;; *) mode="через провайдера" ;; esac

if [ "$S_enabled" != 1 ]; then
    st=off; t="Основные правила выключены"; d="Для устройств без отдельного правила действует обычная маршрутизация роутера."
    [ "$S_ai_active" = 1 ] && d="$d Защита адресов Claude Code и ChatGPT включена."
    [ "${S_devices_n:-0}" -gt 0 ] && d="$d Правила для отдельных устройств остаются в силе."
elif [ "$S_killtest" = 1 ]; then
    st=warn; t="Идёт проверка блокировки"; d="Администратор временно включил ограничения на случай сбоя VPN. Дождитесь окончания проверки."
elif [ "$S_tunnel" = 1 ] && [ "$S_rule" = 1 ]; then
    st=ok; t="Основной VPN работает"; d="По общим правилам российские адреса доступны через провайдера, зарубежные — через VPN.${since:+ VPN работает с $since.}"
elif [ "$S_tunnel" = 1 ]; then
    st=warn; t="VPN отвечает, маршрут ещё не включён"; d="Роутер проверит маршрут снова в течение минуты. Если статус сохранится, обратитесь к администратору."
elif [ "$S_kill" = 1 ]; then
    st=bad; t="VPN не работает"
    if [ "$S_failmode" = soft ]; then d="Включена блокировка с исключениями. Выбранные сети доступны через провайдера."; else d="Роутер блокирует зарубежные адреса, для которых требуется VPN."; fi
    d="$d Сайты на российских адресах могут открываться частично, если загружают данные через VPN.${since:+ VPN не работает с $since${ago:+ ($ago)}.}"
elif [ "${S_fails:-0}" -lt 2 ] 2>/dev/null; then
    st=warn; t="VPN не отвечает"; d="Роутер повторит проверку через минуту. Выбранный режим при сбое — «$mode»."
else
    st=warn; t="VPN не работает"; d="Выбранный режим при сбое — «$mode». Маршрут для конкретного адреса можно проверить ниже.${since:+ VPN не работает с $since${ago:+ ($ago)}.}"
    [ "$S_ai_active" = 1 ] && d="$d Для защищённых AI-адресов прямой маршрут через провайдера запрещён."
fi
contact=$(cat "$DIR/contact.txt" 2>/dev/null | head -c 600 | esc | sed 's/$/<br>/')

log_end=$(param log_end "${QUERY_STRING:-}")
case "$log_end" in ''|*[!0-9]*|??????????*|0) log_end= ;; esac
status_caption='страница статуса · обновляется сама'
[ -z "$log_end" ] || status_caption='страница статуса · просмотр истории'

printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
cat <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
$([ -z "$log_end" ] && echo '<meta http-equiv="refresh" content="30">')
<meta name="color-scheme" content="light dark">
<title>Razvilka — статус</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/journal.css">
<style>
:root{--bg:#f6f3ee;--card:#fff;--fg:#1d1b20;--mut:#67626d;--line:#e6e0d8;
--acc:#5046e5;--accs:#eceafe;--accfg:#fff;--isp:#0d7a63;--ispb:#e1f4ef;--vpn:#6a48d7;--vpnb:#efeafd;
--ok:#16803c;--okb:#e5f5ea;--bad:#c4261d;--badb:#fdeceb;--warn:#a85208;--warnb:#fdf1dc;--off:#5c6270;--offb:#eceef2}
@media (prefers-color-scheme:dark){:root{--bg:#121317;--card:#191b20;--fg:#eceaf0;--mut:#a29daa;--line:#2b2e36;
--acc:#a29bff;--accs:#25233f;--accfg:#17153a;--isp:#4fd3b5;--ispb:#11302a;--vpn:#b9a4ff;--vpnb:#261f42;
--ok:#5fd48d;--okb:#11291b;--bad:#ff8b82;--badb:#341719;--warn:#f6c564;--warnb:#2e2413;--off:#aab0bc;--offb:#23262c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:640px;margin:0 auto;padding:20px 16px 32px}
.top{display:flex;align-items:center;gap:12px;margin-bottom:18px}.top svg{display:block}
.top b{font-size:18px}.top span{display:block;color:var(--mut);font-size:13px}
.hero{border-radius:20px;padding:22px 20px;background:var(--c2);border:1px solid var(--line);border-left:6px solid var(--c)}
.hero.ok{--c:var(--ok);--c2:var(--okb)}.hero.bad{--c:var(--bad);--c2:var(--badb)}.hero.warn{--c:var(--warn);--c2:var(--warnb)}.hero.off{--c:var(--off);--c2:var(--offb)}
.hero h1{margin:0 0 6px;font-size:26px;line-height:1.2;color:var(--c)}.hero p{margin:0;font-size:17px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin:14px 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px 14px}
.tile .k{font-size:13px;color:var(--mut)}.tile .v{font-weight:600}
.lookup{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px;margin:14px 0}
.lookup h2{margin:0 0 12px;color:var(--fg);font-size:16px;text-transform:none;letter-spacing:-.01em}
.lookup label{display:block;font-size:13px;font-weight:600;margin-bottom:6px}
.row{display:flex;gap:8px}.row input{flex:1;min-width:0}.row button{flex:none}
input,button{font:inherit;min-height:44px;padding:9px 12px;border:1px solid var(--line);border-radius:11px}
input{width:100%;background:var(--bg);color:var(--fg)}button{background:var(--acc);color:var(--accfg);border-color:var(--acc);font-weight:600;cursor:pointer}
input:focus,button:focus-visible,a:focus-visible{outline:3px solid var(--acc);outline-offset:2px}
.res{display:grid;gap:10px;margin-top:14px}.rsum{margin:0;font-size:15px;overflow-wrap:anywhere}
.ipr{border:1px solid var(--line);border-radius:12px;padding:11px 12px;background:var(--bg)}
.iph{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.iph code{font:600 13px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;overflow-wrap:anywhere}
.bdg{font-size:12px;font-weight:700;border-radius:999px;padding:3px 9px}.bdg.vpn{color:var(--vpn);background:var(--vpnb)}
.bdg.isp{color:var(--isp);background:var(--ispb)}.bdg.loc{color:var(--off);background:var(--offb)}
.why{font-size:14px;margin:6px 0 0}.mut{color:var(--mut);font-size:13px}
.help{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:14px}
h2{font-size:14px;color:var(--mut);margin:18px 0 8px;font-weight:600;text-transform:uppercase;letter-spacing:.04em}
footer{color:var(--mut);font-size:12px;margin-top:16px;text-align:center}
@media (max-width:380px){.row{flex-direction:column}.row button{width:100%}}
</style></head><body><main>
<div class="top"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="36" height="36" aria-hidden="true" focusable="false"><defs><linearGradient id="rzv-mark-bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6359f0"/><stop offset="1" stop-color="#3a2fc2"/></linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#rzv-mark-bg)"/><g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="6"><path d="M32 39 C32 29 19 28 19 15 M12.5 20.5 L19 14 L25.5 20.5" stroke="#4fd3b5"/><path d="M32 39 C32 29 45 28 45 15 M38.5 20.5 L45 14 L51.5 20.5" stroke="#cbbcff"/><path d="M32 53 V39" stroke="#fff"/></g><circle cx="32" cy="39" r="5.5" fill="#fff"/></svg><div><b>Razvilka</b><span>$status_caption</span></div></div>
<div class="hero $st"><h1>$t</h1><p>$d</p></div>
<div class="grid">
<div class="tile"><div class="k">VPN</div><div class="v">$([ "$S_tunnel" = 1 ] && echo "работает" || echo "не работает")${ago:+ · $ago}</div></div>
<div class="tile"><div class="k">Если VPN не работает</div><div class="v">$mode</div></div>
$([ "$S_ai_active" = 1 ] && echo '<div class="tile"><div class="k">Claude Code / ChatGPT</div><div class="v">защита адресов включена</div></div>')
$([ "$S_ipv6_blocked" = 1 ] && echo '<div class="tile"><div class="k">Внешний IPv6</div><div class="v">заблокирован</div></div>')
<div class="tile"><div class="k">VPN · получено / отправлено</div><div class="v">$(fmt_bytes "${S_vpn_rx_bytes:-0}") / $(fmt_bytes "${S_vpn_tx_bytes:-0}")</div></div>
<div class="tile"><div class="k">Последняя проверка</div><div class="v">${checked:-—}${checked:+ назад}</div></div>
<div class="tile"><div class="k">Список российских сетей</div><div class="v">${S_ru_date:-—}</div></div>
</div>
<section class="lookup" id="check" aria-labelledby="lookup-title">
<h2 id="lookup-title">Проверка маршрута</h2>
<label for="status-host">Домен или IPv4-адрес</label>
<form method="get" action="/status" class="row"><input id="status-host" name="host" placeholder="kion.ru или 1.2.3.4" value="$host" autocapitalize="off" autocorrect="off" spellcheck="false" required><button type="submit">Проверить</button></form>
<p class="mut">Результат учитывает правила устройства, с которого открыта эта страница.</p>
EOF
if [ -n "$host" ]; then
    # dig, а не nslookup: busybox nslookup дописывает после IP имя из PTR-записи
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then ips=$host; elif [ "${host#-}" != "$host" ]; then ips=; else
    ips=$("$DIG" +short +time=3 +tries=1 "$host" A "@$DNS" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | sort -u); fi
    echo '<div class="res">'
    if [ -z "$ips" ]; then
        echo "<p class=\"rsum\">Не удалось найти адрес <b>$host</b>. Проверьте написание домена или введите IPv4-адрес.</p>"
    else
        rows=; nv=0; nd=0; nb=0; nl=0; nu=0; na=0
        for ip in $ips; do
            lk=$($FVPN lookup "$ip" "${REMOTE_ADDR:-}" brief 2>/dev/null)
            g() { echo "$lk" | sed -n "s/^$1=//p"; }
            dev=$(g dev | head -1); tbl=$(g table | head -1); ai=$(g ai | head -1); blocked=$(g blocked | head -1)
            na=$((na+1))
            if [ "$ai" = 1 ] && [ "$blocked" = 1 ]; then
                nb=$((nb+1)); badge='<span class="bdg loc">заблокировано</span>'; why="Для этого устройства прямой доступ закрыт. Адрес входит в список защиты Claude Code и ChatGPT."
            elif [ "$blocked" = 1 ]; then
                nb=$((nb+1)); badge='<span class="bdg loc">заблокировано</span>'; why="Правила роутера блокируют это соединение."
            elif [ -n "$dev" ] && { [ "$dev" = "$S_vpn_if" ] || [ "$dev" = "$S_vpn2_if" ]; }; then
                nv=$((nv+1)); badge='<span class="bdg vpn">через VPN</span>'
                case "$tbl" in
                    103*) why="Для устройства выбран этот VPN." ;;
                    1019) why="Адрес входит в список защиты Claude Code и ChatGPT." ;;
                    1020) why="Для адреса задано ручное правило «Через VPN»." ;;
                    *) why="Действует основной маршрут через VPN." ;;
                esac
            elif echo "$dev" | grep -q '^br'; then
                nl=$((nl+1)); badge='<span class="bdg loc">локальная сеть</span>'; why="Адрес домашней сети, внешний маршрут не нужен."
            elif [ -n "$dev" ]; then
                nd=$((nd+1)); badge='<span class="bdg isp">напрямую</span>'
                case "$tbl" in
                    1020) why="Для адреса задано ручное правило «Напрямую»." ;;
                    1022) if [ "$(g ru)" = 1 ]; then why="Российская сеть из списка прямой маршрутизации."; else why="Для адреса действует прямой маршрут."; fi ;;
                    *) why="Роутер направляет соединение через провайдера." ;;
                esac
            else
                nu=$((nu+1)); badge='<span class="bdg loc">маршрут неизвестен</span>'; why="Не удалось определить интерфейс маршрута."
            fi
            rows="$rows<div class=\"ipr\"><div class=\"iph\"><code>$ip</code>$badge</div><p class=\"why\">$why</p></div>"
        done
        r100=$((na%100)); r10=$((na%10))
        if [ "$r100" -ge 11 ] && [ "$r100" -le 14 ]; then aw="адресов"; else
            case "$r10" in 1) aw="адрес" ;; 2|3|4) aw="адреса" ;; *) aw="адресов" ;; esac
        fi
        parts=
        [ "$nv" -gt 0 ] && parts="$parts, $nv через VPN"
        [ "$nd" -gt 0 ] && parts="$parts, $nd напрямую"
        [ "$nb" -gt 0 ] && parts="$parts, $nb заблокировано"
        [ "$nl" -gt 0 ] && parts="$parts, $nl в локальной сети"
        [ "$nu" -gt 0 ] && parts="$parts, $nu с неизвестным маршрутом"
        echo "<p class=\"rsum\"><b>$host</b>: $na $aw — ${parts#, }.</p>"
        echo "$rows"
    fi
    echo '</div>'
fi
cat <<EOF
</section>
EOF
[ -n "$contact" ] && [ "$st" != ok ] && printf '<div class="help"><b>Контакт для связи</b><br>%s</div>\n' "$contact"
echo '<section id="journal" aria-labelledby="journal-title"><h2 id="journal-title">Последние события</h2>'
log_source=/dev/null
[ -f "$LOG" ] && [ ! -L "$LOG" ] && log_source=$LOG
awk -v public_view=1 -v cursor="$log_end" -f "$DIR/journal.awk" "$log_source" || echo '<p class="journal-empty">Не удалось прочитать события.</p>'
echo '</section><footer><a href="/admin">Панель управления</a> · <a href="/admin#journal">Полный журнал</a> · вход по паролю</footer></main></body></html>'
