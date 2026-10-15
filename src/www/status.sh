#!/bin/sh
# Страница статуса Razvilka: http://<роутер>:98/status — без пароля, только чтение, ничего не принимает на вход.
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root
DIR=${RZ_TEST_DIR:-/opt/razvilka}
FVPN=${RZ_TEST_FVPN:-$DIR/razvilka.sh}
LOG=${RZ_TEST_LOG:-/opt/var/log/razvilka.log}

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
eval "$($FVPN status-kv 2>/dev/null | grep -E '^[a-z_]+=[A-Za-z0-9 .:/_-]*$' | sed -E "s/^([a-z_]+)=(.*)$/S_\1='\2'/")"

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

case "$S_failmode" in soft) mode="мягкий kill: закрыто, кроме CDN и т.п." ;; kill) mode="строгий kill: закрыто всё зарубежное" ;; *) mode="пускать напрямую" ;; esac

if [ "$S_enabled" != 1 ]; then
    st=off; t="Razvilka выключена"; d="Весь трафик идёт напрямую через провайдера."
elif [ "$S_killtest" = 1 ]; then
    st=warn; t="Идёт проверка"; d="Зарубежное на несколько минут закрыто для теста, потом всё вернётся само."
elif [ "$S_tunnel" = 1 ]; then
    st=ok; t="Всё работает"; d="Российские сайты — напрямую, зарубежные — через VPN.${since:+ VPN работает с $since.}"
elif [ "$S_kill" = 1 ]; then
    st=bad; t="VPN не работает"
    if [ "$S_failmode" = soft ]; then d="Зарубежные сайты закрыты, кроме служебных (CDN, шрифты, капча)."; else d="Зарубежные сайты закрыты."; fi
    d="$d Российские сайты работают как обычно.${since:+ VPN не работает с $since${ago:+ ($ago)}.}"
elif [ "${S_fails:-0}" -lt 2 ] 2>/dev/null; then
    st=warn; t="VPN не отвечает"; d="Проверяю ещё раз — если не оживёт, через минуту сработает режим «$mode»."
else
    st=warn; t="VPN не работает"; d="Зарубежные сайты идут напрямую, без VPN — могут открываться медленнее. Российские работают.${since:+ VPN не работает с $since${ago:+ ($ago)}.}"
fi
contact=$(cat "$DIR/contact.txt" 2>/dev/null | head -c 600 | esc | sed 's/$/<br>/')

printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
cat <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<meta name="color-scheme" content="light dark">
<title>Razvilka — статус</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<style>
:root{--bg:#f6f3ee;--card:#fff;--fg:#1d1b20;--mut:#67626d;--line:#e6e0d8;
--ok:#16803c;--okb:#e5f5ea;--bad:#c4261d;--badb:#fdeceb;--warn:#a85208;--warnb:#fdf1dc;--off:#5c6270;--offb:#eceef2}
@media (prefers-color-scheme:dark){:root{--bg:#121317;--card:#191b20;--fg:#eceaf0;--mut:#a29daa;--line:#2b2e36;
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
.help{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:14px}
h2{font-size:14px;color:var(--mut);margin:18px 0 8px;font-weight:600;text-transform:uppercase;letter-spacing:.04em}
ul{margin:0;padding:0;list-style:none;background:var(--card);border:1px solid var(--line);border-radius:14px}
li{padding:9px 14px;border-top:1px solid var(--line);font-size:14px}li:first-child{border-top:0}
li time{color:var(--mut);font-variant-numeric:tabular-nums;margin-right:8px}
footer{color:var(--mut);font-size:12px;margin-top:16px;text-align:center}
</style></head><body><main>
<div class="top"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="36" height="36" aria-hidden="true" focusable="false"><defs><linearGradient id="rzv-mark-bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6359f0"/><stop offset="1" stop-color="#3a2fc2"/></linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#rzv-mark-bg)"/><g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="6"><path d="M32 39 C32 29 19 28 19 15 M12.5 20.5 L19 14 L25.5 20.5" stroke="#4fd3b5"/><path d="M32 39 C32 29 45 28 45 15 M38.5 20.5 L45 14 L51.5 20.5" stroke="#cbbcff"/><path d="M32 53 V39" stroke="#fff"/></g><circle cx="32" cy="39" r="5.5" fill="#fff"/></svg><div><b>Razvilka</b><span>страница статуса · обновляется сама</span></div></div>
<div class="hero $st"><h1>$t</h1><p>$d</p></div>
<div class="grid">
<div class="tile"><div class="k">VPN</div><div class="v">$([ "$S_tunnel" = 1 ] && echo "работает" || echo "не работает")${ago:+ · $ago}</div></div>
<div class="tile"><div class="k">Если VPN не работает</div><div class="v">$mode</div></div>
<div class="tile"><div class="k">Последняя проверка</div><div class="v">${checked:-—}${checked:+ назад}</div></div>
<div class="tile"><div class="k">Список российских сетей</div><div class="v">${S_ru_date:-—}</div></div>
</div>
EOF
[ -n "$contact" ] && [ "$st" != ok ] && printf '<div class="help"><b>Если долго не работает — напишите:</b><br>%s</div>\n' "$contact"
echo '<h2>Последние события</h2><ul>'
# события человеческим языком; служебное (перезапуски, перестройка таблиц) не показываем
grep -E 'KILL SWITCH|туннель не отвечает|туннель жив|режим при падении|тест kill switch на' "$LOG" 2>/dev/null \
  | sed -E -e 's/туннель не отвечает.*напрямую$/VPN перестал отвечать — зарубежное пошло напрямую/' \
           -e 's/туннель не отвечает.*/VPN перестал отвечать/' \
           -e 's/туннель жив.*/VPN снова работает/' \
           -e 's/KILL SWITCH ВКЛ \(мягкий.*/Зарубежное закрыто, кроме CDN и т.п. (мягкий kill)/' \
           -e 's/KILL SWITCH ВКЛ.*/Зарубежное закрыто (строгий kill)/' \
           -e 's/режим при падении VPN: direct/Режим при падении VPN: пускать напрямую/' \
           -e 's/режим при падении VPN: soft/Режим при падении VPN: мягкий kill/' \
           -e 's/режим при падении VPN: kill/Режим при падении VPN: строгий kill/' \
           -e 's/тест kill switch на ([0-9]+) мин/Проверка kill switch на \1 мин/' \
  | tail -n 8 | sed -n '1!G;h;$p' | esc \
  | awk '{ printf "<li><time>%s %s</time>", substr($1,9,2) "." substr($1,6,2), substr($2,1,5); $1=""; $2=""; sub(/^  /,""); print $0 "</li>" }'
echo '</ul><footer>Настройки — <a href="/">панель управления</a> (нужен пароль)</footer></main></body></html>'
