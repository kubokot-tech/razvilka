#!/bin/sh
# Веб-морда razvilka: http://<роутер>:98 (логин/пароль — /opt/razvilka/web.users)
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root
FVPN=/opt/razvilka/razvilka.sh
DIR=/opt/razvilka
LOG=/opt/var/log/razvilka.log
LISTS=/opt/razvilka/lists

urldecode() {
    awk 'BEGIN{for(i=0;i<256;i++) h[sprintf("%02x",i)]=sprintf("%c",i)}
    {s=$0; gsub(/\+/," ",s); o="";
     while (match(s,/%[0-9A-Fa-f][0-9A-Fa-f]/)) {o=o substr(s,1,RSTART-1) h[tolower(substr(s,RSTART+1,2))]; s=substr(s,RSTART+3)}
     printf "%s", o s}'
}
param() { printf '%s' "$2" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2- | urldecode; }
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
redirect() { printf 'Status: 303 See Other\r\nLocation: /?msg=%s\r\n\r\n' "$1"; exit 0; }

# ---------- действия (POST) ----------
if [ "$REQUEST_METHOD" = POST ]; then
    body=$(head -c "${CONTENT_LENGTH:-0}")
    exec </dev/null   # дальше никто не должен читать соединение с браузером
    a=$(param action "$body")
    case "$a" in
        start)        $FVPN start >/dev/null 2>&1; redirect started ;;
        stop)         $FVPN stop >/dev/null 2>&1; redirect stopped ;;
        mode_kill)    $FVPN mode kill >/dev/null 2>&1; redirect mode ;;
        mode_direct)  $FVPN mode direct >/dev/null 2>&1; redirect mode ;;
        check)        $FVPN watchdog >/dev/null 2>&1; redirect checked ;;
        update)       $FVPN update >/dev/null 2>&1; redirect updated ;;
        killtest)     $FVPN killtest 3 >/dev/null 2>&1; redirect killtest ;;
        killtest_off) $FVPN killtest off >/dev/null 2>&1; redirect killtest_off ;;
        vpn_restart)  $FVPN vpn-restart >/dev/null 2>&1; redirect vpn_restart ;;
        save_list)
            l=$(param list "$body")
            case "$l" in isp) f=$LISTS/direct.list ;; vpn) f=$LISTS/vpn.list ;; *) redirect unknown ;; esac
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
            $FVPN lists >/dev/null 2>&1
            echo "$l" > "$DIR/last_save_list"
            redirect saved ;;
        contact)
            param contact "$body" | tr -d '\r' | head -c 600 > "$DIR/contact.txt"
            $FVPN stub >/dev/null 2>&1; redirect contact ;;
        *) redirect unknown ;;
    esac
fi

# ---------- страница (GET) ----------
q=$QUERY_STRING
msg=$(param msg "$q")
host=$(param host "$q" | tr -cd 'A-Za-z0-9.-' | head -c 253)

eval "$($FVPN status-kv 2>/dev/null | grep -E '^[a-z_]+=[A-Za-z0-9 .:/_-]*$' | sed -E "s/^([a-z_]+)=(.*)$/S_\1='\2'/")"

case "$msg" in
    started) m="Схема включена." ;;  stopped) m="Схема выключена: весь трафик идёт напрямую." ;;
    mode) m="Режим при падении VPN изменён." ;; checked) m="Проверка выполнена." ;;
    updated) m="Список российских сетей обновлён." ;; killtest) m="Заглушка включена на 3 минуты. Откройте любой http-сайт, например http://neverssl.com" ;;
    killtest_off) m="Тест заглушки остановлен." ;; vpn_restart) m="VPN перезапущен." ;;
    contact) m="Контакт сохранён, заглушка обновлена." ;;
    saved) ln=$(cat "$DIR/last_save_list" 2>/dev/null)
           m="Список «$([ "$ln" = isp ] && echo "всегда напрямую" || echo "всегда через VPN")» сохранён и применён."
           [ -s "$DIR/last_save.txt" ] && m="$m Не распознаны и отброшены: $(tr '\n' ' ' < "$DIR/last_save.txt")" ;;
    *) m= ;;
esac

if [ "$S_enabled" != 1 ]; then st="off"; stt="Схема выключена"; std="Весь трафик идёт напрямую, как без пакета. Ручные списки не действуют."
elif [ "$S_killtest" = 1 ]; then st="warn"; stt="Тест заглушки"; std="Зарубежное с устройств закрыто, HTTP показывает заглушку. Само выключится через 3 минуты."
elif [ "$S_tunnel" = 1 ] && [ "$S_rule" = 1 ]; then st="ok"; stt="Всё работает"; std="Иностранный трафик идёт через VPN, российский — напрямую."
elif [ "$S_kill" = 1 ]; then st="bad"; stt="VPN упал — kill switch включён"; std="Зарубежное с устройств закрыто, HTTP-сайты показывают заглушку. Российские сайты работают."
elif [ "$S_tunnel" != 1 ] && [ "$S_rule" != 1 ]; then st="bad"; stt="VPN упал — зарубежное напрямую"; std="Иностранные сайты открываются напрямую, с заморозками провайдера."
elif [ "$S_tunnel" != 1 ]; then st="warn"; stt="VPN не отвечает"; std="Проверка $S_fails из 2 — если не оживёт, сработает режим «при падении VPN»."
else st="warn"; stt="Туннель жив, правило ещё не включено"; std="Сторож включит его в течение минуты."
fi

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
<style>
:root{
--bg:#f6f3ee;--bg2:#eee9e2;--card:#fff;--fg:#1d1b20;--mut:#67626d;--line:#e6e0d8;
--acc:#5046e5;--acch:#4338ca;--accfg:#fff;--accs:#eceafe;--glow:rgba(99,88,240,.14);
--ok:#16803c;--okb:#e5f5ea;--bad:#c4261d;--badb:#fdeceb;--warn:#a85208;--warnb:#fdf1dc;--off:#5c6270;--offb:#eceef2;
--isp:#0d7a63;--ispb:#e1f4ef;--vpn:#6a48d7;--vpnb:#efeafd;
--term:#15171c;--termfg:#d5dce6;--termmut:#7d8696;
--sh:0 1px 2px rgba(29,27,32,.04),0 10px 30px -14px rgba(29,27,32,.16);
--r:18px;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace;
color-scheme:light}
@media (prefers-color-scheme:dark){:root{
--bg:#121317;--bg2:#1d2026;--card:#191b20;--fg:#eceaf0;--mut:#a29daa;--line:#2b2e36;
--acc:#a29bff;--acch:#b9b3ff;--accfg:#17153a;--accs:#25233f;--glow:rgba(130,120,255,.16);
--ok:#5fd48d;--okb:#11291b;--bad:#ff8b82;--badb:#341719;--warn:#f6c564;--warnb:#2e2413;--off:#aab0bc;--offb:#23262c;
--isp:#4fd3b5;--ispb:#11302a;--vpn:#b9a4ff;--vpnb:#261f42;
--term:#0c0d10;--termfg:#d5dce6;--termmut:#6f7888;
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
input,textarea{font:inherit;width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--fg);
transition:border-color .15s,box-shadow .15s}
input{min-height:44px}
input:focus,textarea:focus{border-color:var(--acc);box-shadow:0 0 0 3px var(--accs);outline:none}
::placeholder{color:var(--mut);opacity:.75}
.row{display:flex;gap:8px}.row input{flex:1;min-width:0}.row button{flex:none}
pre{margin:12px 0 0;padding:12px 14px;border-radius:12px;background:var(--bg);border:1px solid var(--line);
font:12.5px/1.6 var(--mono);white-space:pre-wrap;overflow-wrap:anywhere;overflow-x:auto}
.check pre{border-left:4px solid var(--acc)}
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
.term{background:var(--term);border-radius:var(--r);overflow:hidden;margin-bottom:14px;box-shadow:var(--sh);border:1px solid var(--line)}
.term .bar{display:flex;align-items:center;gap:7px;padding:11px 14px;border-bottom:1px solid rgba(255,255,255,.07);color:var(--termmut);font-size:12.5px;font-weight:600}
.term .bar i{width:11px;height:11px;border-radius:50%;background:#ff5f57}.term .bar i+i{background:#febc2e}.term .bar i+i+i{background:#28c840;margin-right:6px}
.term pre{margin:0;border:0;border-radius:0;background:transparent;color:var(--termfg);padding:14px 16px 16px;max-height:340px;overflow:auto;font-size:12px}
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
@media (max-width:380px){.hero{flex-direction:column;align-items:flex-start}.top .ref span{display:none}}
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
</style></head><body><main>
<header class="top">
<div class="logo" aria-hidden="true"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="40" height="40" aria-hidden="true" focusable="false"><defs><linearGradient id="rzv-mark-bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6359f0"/><stop offset="1" stop-color="#3a2fc2"/></linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#rzv-mark-bg)"/><g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="6"><path d="M32 39 C32 29 19 28 19 15 M12.5 20.5 L19 14 L25.5 20.5" stroke="#4fd3b5"/><path d="M32 39 C32 29 45 28 45 15 M38.5 20.5 L45 14 L51.5 20.5" stroke="#cbbcff"/><path d="M32 53 V39" stroke="#fff"/></g><circle cx="32" cy="39" r="5.5" fill="#fff"/></svg></div>
<div><h1>Razvilka</h1><p>Иностранное через VPN, российское напрямую</p></div>
<a class="ref" href="/"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/></svg><span>Обновить</span></a>
</header>
EOF
[ -n "$m" ] && printf '<div class="msg" role="status"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.01"/></svg><div>%s</div></div>\n' "$(printf '%s' "$m" | esc)"
cat <<EOF
<section class="hero $st" aria-live="polite">
<div class="ico" aria-hidden="true"><svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">$ico</svg></div>
<div class="txt"><div class="kick"><span class="dot"></span>Состояние</div><h2>$stt</h2><p>$std</p></div>
</section>

<div class="tiles">
<div class="tile"><span class="k">VPN-туннель</span><span class="v"><i class="led $([ "$S_tunnel" = 1 ] && echo on || echo no)"></i>$([ "$S_tunnel" = 1 ] && echo "жив" || echo "не отвечает")</span>${S_vpn_ip:+<small>$S_vpn_ip</small>}</div>
<div class="tile"><span class="k">При падении VPN</span><span class="v">$([ "$S_failmode" = kill ] && echo "заглушка (kill switch)" || echo "напрямую")</span></div>
<div class="tile"><span class="k">Сети РФ напрямую</span><span class="v">${S_ru:-0}</span><small>обновлён ${S_ru_date:-—}</small></div>
<div class="tile"><span class="k">Сервер VPN напрямую</span><span class="v">${S_servers:-—}</span></div>
<div class="tile"><span class="k">Ручные списки</span><span class="v">${S_direct_n:-0} напрямую · ${S_vpn_n:-0} через VPN</span></div>
<div class="tile"><span class="k">Шлюз провайдера</span><span class="v">${S_gw:-—}</span></div>
</div>

<section class="card">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg></span>Управление</h2>
<div class="actions">
$(if [ "$S_enabled" = 1 ]; then echo '<form method="post"><button class="danger" name="action" value="stop">Выключить схему</button></form>'; else echo '<form method="post"><button class="pri" name="action" value="start">Включить схему</button></form>'; fi)
<form method="post"><button name="action" value="check">Проверить сейчас</button></form>
<form method="post"><button class="danger" name="action" value="vpn_restart">Перезапустить VPN</button></form>
<form method="post"><button name="action" value="update">Обновить список РФ</button></form>
</div>

<div class="sub">Если VPN упал</div>
<p class="mut" style="margin:-4px 0 10px">Проверка раз в минуту, срабатывает после 2 неудач подряд.</p>
<div class="seg" role="group" aria-label="Режим при падении VPN">
<form method="post"><button class="$([ "$S_failmode" = kill ] && echo sel)" aria-pressed="$([ "$S_failmode" = kill ] && echo true || echo false)" name="action" value="mode_kill"><span>Заглушка</span><small>kill switch</small></button></form>
<form method="post"><button class="$([ "$S_failmode" = direct ] && echo sel)" aria-pressed="$([ "$S_failmode" = direct ] && echo true || echo false)" name="action" value="mode_direct"><span>Пускать напрямую</span><small>с заморозками провайдера</small></button></form>
</div>
<div class="note"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.01"/></svg>
<span>HTTP-сайты показывают страницу-заглушку, HTTPS и приложения сразу получают отказ (подменить HTTPS без ошибки сертификата нельзя). Телефоны обычно сами открывают окно «Войдите в сеть» с заглушкой.</span></div>
<div class="inline">
$(if [ "$S_killtest" = 1 ]; then echo '<form method="post"><button class="pri" name="action" value="killtest_off">Остановить тест заглушки</button></form>'; else echo '<form method="post"><button name="action" value="killtest">Тест заглушки на 3 минуты</button></form>'; fi)
<a class="btn" href="http://${S_lan_ip:-192.168.1.1}:${S_stub_port:-8098}/" target="_blank">Посмотреть заглушку ↗</a>
</div>
</section>

<section class="card check">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg></span>Куда пойдёт сайт</h2>
<form method="get" class="row"><input name="host" aria-label="Домен или IP" placeholder="kion.ru или 1.2.3.4" value="$host" autocapitalize="off" autocorrect="off" spellcheck="false"><button class="pri">Проверить</button></form>
EOF
if [ -n "$host" ]; then
    # dig, а не nslookup: busybox nslookup дописывает после IP имя из PTR-записи
    if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then ips=$host; isip=1; else
    ips=$(dig +short +time=3 +tries=1 "$host" A @127.0.0.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | sort -u); isip=; fi
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
        rows=; nv=0; nd=0
        for ip in $ips; do
            lk=$($FVPN lookup "$ip" 2>/dev/null)
            g() { echo "$lk" | sed -n "s/^$1=//p"; }
            dev=$(g dev | head -1); tbl=$(g table | head -1)
            md=$(g match_direct | tr '\n' ' '); mv=$(g match_vpn | tr '\n' ' ')
            if [ "$dev" = "$S_vpn_if" ]; then nv=$((nv+1)); badge='<span class="bdg vpn">через VPN</span>'
            elif echo "$dev" | grep -q '^br'; then badge='<span class="bdg loc">локальная сеть</span>'
            else nd=$((nd+1)); badge='<span class="bdg isp">напрямую</span>'; fi
            case "$tbl:$dev" in
                1020:"$S_vpn_if") why="ручной список «через VPN»" ;;
                1020:*)           why="ручной список «напрямую»" ;;
                *:"$S_vpn_if")    why="зарубежный адрес — всё зарубежное идёт через VPN" ;;
                1022:*)           why="российская сеть" ;;
                *:br*)            why="адрес домашней сети" ;;
                *)                why="обычная маршрутизация роутера" ;;
            esac
            chips=
            for e in $md; do chips="$chips<span class=\"chip isp\">в «напрямую»: $(echo "$e" | esc)</span>"; done
            for e in $mv; do chips="$chips<span class=\"chip vpn\">в «через VPN»: $(echo "$e" | esc)</span>"; done
            [ -n "$md" ] && [ -n "$mv" ] && chips="$chips<span class=\"chip mut\">есть в обоих — «напрямую» важнее</span>"
            [ "$(g ru)" = 1 ] && chips="$chips<span class=\"chip mut\">сеть РФ</span>" || chips="$chips<span class=\"chip mut\">зарубежная сеть</span>"
            as=$(g asn); [ -n "$as" ] && chips="$chips<span class=\"chip mut\">AS$as $(g holder | esc)</span>"
            rows="$rows<div class=\"ipr\"><div class=\"iph\"><code>$ip</code>$badge</div><div class=\"why\">$why</div><div class=\"chips2\">$chips</div></div>"
        done
        n=$((nv+nd))
        if [ "$nv" -gt 0 ] && [ "$nd" -eq 0 ]; then sum="идёт <b class=\"tv\">через VPN</b>"
        elif [ "$nd" -gt 0 ] && [ "$nv" -eq 0 ]; then sum="идёт <b class=\"ti\">напрямую</b>"
        elif [ "$n" -gt 0 ]; then sum="идёт по-разному: $nd адрес(а) напрямую, $nv через VPN"
        else sum="— локальный адрес"; fi
        echo "<p class=\"rsum\"><b>$host</b> $sum</p>"
        if [ -z "$isip" ]; then
            case "$inl" in
                *direct*vpn*) echo '<p class="rdom">Домен записан в обоих списках — действует «напрямую».</p>' ;;
                *direct*) echo '<p class="rdom">Домен записан в списке <span class="chip isp">напрямую</span></p>' ;;
                *vpn*)    echo '<p class="rdom">Домен записан в списке <span class="chip vpn">через VPN</span></p>' ;;
                *)        echo '<p class="rdom mut">Самого домена в ручных списках нет.</p>' ;;
            esac
        fi
        echo "$rows"
    fi
    echo '</div>'
fi
cat <<EOF
<p class="mut" style="margin:12px 0 0">Исключения — в ручных списках ниже.</p>
</section>

<section class="card">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6h11M9 12h11M9 18h11"/><path d="M4.5 6h.01M4.5 12h.01M4.5 18h.01"/></svg></span>Ручные списки</h2>
<div class="chips"><span>домен <b>kion.ru</b></span><span>IP <b>1.2.3.4</b></span><span>подсеть <b>5.6.0.0/16</b></span><span>автономная система <b>AS13238</b></span><span><b>#</b> комментарий</span></div>
<p class="mut" style="margin:0">По одной записи на строку. Поддомены — отдельно (<code>www.kion.ru</code>), русские домены — в punycode (<code>xn--...</code>).
Домены превращаются в IP при сохранении и каждый час, AS — в свои подсети (RIPEstat, раз в сутки). Эти списки важнее всего остального.</p>
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

<section class="card">
<h2><span class="b" aria-hidden="true"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8l-4 3v-3H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z"/></svg></span>Контакт на заглушке</h2>
<form method="post"><input type="hidden" name="action" value="contact">
<label class="mut" for="contact" style="display:block;margin-bottom:8px">Показывается на заглушке в блоке «Кому написать».</label>
<textarea id="contact" name="contact" rows="3" placeholder="Например: Иван, +7 900 000-00-00, Telegram @...">$(cat "$DIR/contact.txt" 2>/dev/null | esc)</textarea>
<div class="inline" style="margin-top:10px"><button class="pri">Сохранить</button></div></form>
</section>

<section class="term" aria-label="Журнал">
<div class="bar" aria-hidden="true"><i></i><i></i><i></i>razvilka.log</div>
<pre>$(tail -n 15 "$LOG" 2>/dev/null | esc)</pre>
</section>

<footer>Скрипт: <code>/opt/razvilka/razvilka.sh</code> · настройки: <code>/opt/razvilka/razvilka.conf</code></footer>
</main></body></html>
EOF
