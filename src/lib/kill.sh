# shellcheck shell=sh
# ---------- kill switch ----------
#
# Блокирует маршрутизация — без правил в FORWARD и без хука netfilter.d. Прежняя версия (до 15.10)
# при упавшем туннеле включалась на недостроенной таблице 1022: ответы в домашнюю сеть уходили провайдеру,
# и роутер «пропадал» из сети целиком.
#   - table 1022: default -> prohibit (зарубежное с устройств сразу получает отказ от ядра);
#   - записи «через VPN» из ручных списков -> тоже prohibit (не висеть в мёртвом туннеле);
#   - ip rule iif lo -> main (трафик самого роутера — DNS, переподключение VPN — напрямую);
#   - заглушка (только если CAPTIVE_STUB=1, по умолчанию выключена): одно правило nat — tcp/80 на
#     зарубежные адреса -> страница-заглушка. На неё попадают проверки интернета (captive portal), и
#     iPhone/Mac считают сеть «требующей входа» — до «входа» они не пускают через Wi‑Fi вообще ничего,
#     включая российское (проверено 15.10). Поэтому по умолчанию — только мгновенный отказ.
#   - страховка: ip rule to <частные сети> lookup main (prio 30018) — домашняя сеть и роутер доступны
#     при любом состоянии наших таблиц.

KILL_PRIO=30019
CAPTIVE_CHAIN=RAZVILKA_CAPTIVE

# ipset «не трогать заглушкой»: сети РФ + «напрямую» + VPN-сервер + DNS + частные сети.
# Нужен только для одного правила nat (tcp/80 на зарубежные адреса -> заглушка): IP служебных адресов
# проверки интернета (captive.apple.com, connectivitycheck.gstatic.com...) меняются постоянно, списком
# конкретных IP их не поймать. Блокирует при этом маршрутизация, не iptables.
build_set() {
    {
        echo "create ${SET}_tmp hash:net maxelem 131072 -exist"
        echo "flush ${SET}_tmp"
        for p in $PRIVATE; do echo "add ${SET}_tmp $p -exist"; done
        for r in $RESOLVERS; do echo "add ${SET}_tmp $r -exist"; done
        for v in $(vpn_servers); do echo "add ${SET}_tmp $v -exist"; done
        awk '{print "add '"${SET}"'_tmp " $1 " -exist"}' "$RU_LIST"
        [ -f "$DIR/direct.resolved" ] && awk '{print "add '"${SET}"'_tmp " $1 " -exist"}' "$DIR/direct.resolved"
    } > "$DIR/ipset.restore"
    ipset create $SET hash:net maxelem 131072 -exist
    ipset restore < "$DIR/ipset.restore" && ipset swap ${SET}_tmp $SET && ipset destroy ${SET}_tmp
}

captive_on() {
    [ "$CAPTIVE_STUB" = 1 ] || { captive_off; return 0; }
    command -v ipset >/dev/null 2>&1 || return 0
    # пустой или битый набор = заглушка перехватила бы и российские http-сайты — тогда без заглушки
    build_set || { log "заглушка: не собрался ipset — без неё"; captive_off; return 0; }
    [ "$(grep -c '^add' "$DIR/ipset.restore")" -gt 1000 ] || { log "заглушка: в наборе подозрительно мало сетей — без неё"; captive_off; return 0; }
    iptables -t nat -N $CAPTIVE_CHAIN 2>/dev/null
    iptables -t nat -F $CAPTIVE_CHAIN
    iptables -t nat -A $CAPTIVE_CHAIN -p tcp -m set ! --match-set $SET dst -j DNAT --to-destination "$LAN_IP:$STUB_PORT"
    iptables -t nat -C PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN 2>/dev/null \
        || iptables -t nat -I PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN
}
captive_off() {
    while iptables -t nat -C PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN 2>/dev/null; do
        iptables -t nat -D PREROUTING -i $LAN_IF -p tcp --dport 80 -j $CAPTIVE_CHAIN || return 1
    done
    iptables -t nat -F $CAPTIVE_CHAIN 2>/dev/null; iptables -t nat -X $CAPTIVE_CHAIN 2>/dev/null
    ipset destroy $SET 2>/dev/null
    return 0
}

# остатки реализации до 15.10 (ipset + REJECT в FORWARD) — снимаем, если вдруг есть
legacy_kill_off() {
    for r in "nat PREROUTING -i $LAN_IF -p tcp --dport 80 -m set ! --match-set $SET dst -j DNAT --to-destination $LAN_IP:$STUB_PORT" \
             "filter FORWARD -i $LAN_IF -p tcp -m set ! --match-set $SET dst -j REJECT --reject-with tcp-reset" \
             "filter FORWARD -i $LAN_IF -m set ! --match-set $SET dst -j REJECT --reject-with icmp-net-unreachable"; do
        t=${r%% *}; rule=${r#* }
        while iptables -t "$t" -C $rule 2>/dev/null; do iptables -t "$t" -D $rule || return 1; done
    done
    ipset destroy $SET 2>/dev/null
    return 0
}

kill_on() {
    priority_available "$PRIO" "$TABLE" || return 1
    guard_on || return 1
    rule_ensure "$KILL_PRIO" main 'iif lo' || return 1
    echo "route replace prohibit default table $TABLE" > "$DIR/kill.guard.batch"
    batch_apply "$DIR/kill.guard.batch" 'kill switch: не удалось установить prohibit' || return 1
    rule_ensure "$PRIO" "$TABLE" || return 1
    kill_mode=$(failmode)
    kill_signature=$(printf '%s\n' "$kill_mode" "$(isp_gw)" "$(vpn_servers)"
        [ ! -f "$RU_LIST" ] || sha256sum "$RU_LIST"
        [ "$kill_mode" != soft ] || [ ! -f "$DIR/allow.resolved" ] || sha256sum "$DIR/allow.resolved")
    kill_changed=0
    if [ "$kill_signature" != "$(cat "$KILL_FLAG" 2>/dev/null)" ] || ! table_routes "$TABLE" | grep -q '^throw '; then
        build down || return 1
        kill_changed=1
    fi
    gw=$(isp_gw)
    {
        echo "route replace prohibit default table $TABLE"
        # мягкий kill: разрешённое (CDN, шрифты, капча, свои записи) — напрямую
        [ "$(failmode)" = soft ] && [ -n "$gw" ] && [ -f "$DIR/allow.resolved" ] \
            && awk -v gw="$gw" -v d="$ISP_IF" -v t="$TABLE" '{print "route replace " $1 " via " gw " dev " d " table " t}' "$DIR/allow.resolved"
        # публичные DNS — напрямую: иначе устройства с «зашитым» DNS (Android, Chromecast, ноутбуки)
        # потеряют и российские сайты
        [ -n "$gw" ] && for r in $RESOLVERS; do echo "route replace $r via $gw dev $ISP_IF table $TABLE"; done
        [ -f "$DIR/vpn.resolved" ] && grep -vxF -f "$DIR/direct.resolved" "$DIR/vpn.resolved" 2>/dev/null \
            | awk -v t="$FORCE_TABLE" '{print "route replace prohibit " $1 " table " t}'
    } > "$DIR/kill.batch"
    batch_apply "$DIR/kill.batch" 'kill switch: ошибка ip -batch' || return 1
    flush_cache
    captive_on || return 1
    if [ "$kill_changed" = 1 ]; then
        printf '%s\n' "$kill_signature" > "$KILL_FLAG" || return 1
        flush_flows
        log "kill switch: $kill_mode"
    fi
    return 0
}

kill_off() {
    captive_off
    rule_remove "$KILL_PRIO" main 'iif lo' || return 1
    if [ -f "$KILL_FLAG" ]; then
        case "${1:-live}" in
            live) build || return 1; build_force normal || return 1 ;;
            direct) rule_off || return 1; build_force normal || return 1 ;;
            stop) : ;;
        esac
        rm -f "$KILL_FLAG"
        flush_cache; flush_flows
        log "kill switch выкл"
    fi
}
killtest_active() { [ -f "$TEST_UNTIL" ] && [ "$(date +%s)" -lt "$(cat "$TEST_UNTIL")" ]; }

# ---------- страница-заглушка ----------

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

make_stub() {
    mkdir -p "$DIR/stub"
    c=$(cat "$CONTACT" 2>/dev/null | html_escape | sed 's/$/<br>/')
    [ -z "$c" ] && c="Обратитесь к тому, кто настраивал VPN на этом роутере."
    cat > "$DIR/stub/index.html" <<EOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Доступ к сайту ограничен</title>
<style>
:root{--bg:#fbf6ee;--card:#fff;--fg:#2a2622;--mut:#6b625a;--line:#efe5d8;--accent:#e07a3f;
--scr:#ffe3c9;--tv:#f2a46b;--tvd:#c9733d;--face:#7a4a2a;--blob:#fde9d4;
--okb:#e7f5ea;--okl:#cfe9d6;--okf:#1d6b37;--chip:#fff;
--help:#fff3d6;--helpl:#f3dfab;--helpf:#5e4610;
--calm:#eaf1fb;--calmf:#2a4a74;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#1a1714;--card:#24201c;--fg:#f3ece4;--mut:#bfb3a6;--line:#3a332c;--accent:#f0a273;
--scr:#4a3627;--tv:#c98552;--tvd:#9c6237;--face:#ffd9b8;--blob:#2c241d;
--okb:#16291c;--okl:#24432d;--okf:#9be0b0;--chip:#1d2a20;
--help:#33290f;--helpl:#4c3e19;--helpf:#ffe29a;
--calm:#1b2534;--calmf:#bcd4f5;color-scheme:dark}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;min-height:100vh;background:#fbf6ee;background:var(--bg);color:#2a2622;color:var(--fg);
font:19px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
main{max-width:640px;margin:0 auto;padding:28px 16px 40px}
.card{background:#fff;background:var(--card);border:1px solid var(--line);border-radius:28px;padding:28px 24px;
box-shadow:0 2px 4px rgba(60,40,20,.04),0 18px 48px -20px rgba(60,40,20,.22)}
.ill{display:block;width:200px;max-width:70%;height:auto;margin:0 auto 8px}
.ill .blob{fill:var(--blob)}.ill .tv{fill:var(--tv)}.ill .tvd{fill:var(--tvd)}.ill .scr{fill:var(--scr)}
.ill .ln{fill:none;stroke:var(--tvd);stroke-width:4;stroke-linecap:round}
.ill .face{fill:none;stroke:var(--face);stroke-width:3.5;stroke-linecap:round}
.ill .cheek{fill:var(--accent);opacity:.35}
.ill .zz{fill:var(--accent);font:700 18px/1 -apple-system,"Segoe UI",Roboto,sans-serif}
.zz1{animation:float 3.2s ease-in-out infinite}.zz2{animation:float 3.2s ease-in-out .8s infinite}
@keyframes float{0%,100%{transform:translateY(0);opacity:.9}50%{transform:translateY(-5px);opacity:.5}}
h1{font-size:28px;line-height:1.25;margin:6px 0 10px;text-align:center;letter-spacing:-.01em}
.lead{text-align:center;font-size:21px;margin:0 0 6px}
.lead b{color:var(--okf)}
.soft{text-align:center;color:#6b625a;color:var(--mut);margin:0 0 22px}
.box{border-radius:20px;padding:18px 20px;margin:0 0 14px}
.box h2{font-size:20px;line-height:1.3;margin:0 0 10px}
.ok{background:#e7f5ea;background:var(--okb);border:1px solid var(--okl)}
.ok h2{color:var(--okf)}
.chips{margin:0;padding:0;list-style:none}
.chips li{display:inline-block;margin:0 6px 8px 0;padding:6px 14px;border-radius:999px;background:var(--chip);border:1px solid var(--okl);font-weight:600}
.calm{background:var(--calm);color:var(--calmf)}
.calm p{margin:0}
.help{background:#fff3d6;background:var(--help);border:2px solid var(--helpl);color:var(--helpf)}
.help h2{color:var(--helpf)}
.who{font-size:22px;font-weight:700;line-height:1.45;color:var(--fg);overflow-wrap:break-word}
.who a{color:inherit}
.ic{display:inline-block;vertical-align:-4px;margin-right:8px}
small{display:block;text-align:center;color:var(--mut);font-size:14px;margin-top:20px}
@media (min-width:700px){main{padding-top:6vh}.card{padding:36px 40px}h1{font-size:34px}.ill{width:230px}}
@media (min-width:1280px){body{font-size:22px}main{max-width:760px}h1{font-size:40px}.lead{font-size:25px}.box h2{font-size:23px}.who{font-size:26px}.ill{width:270px}}
@media (prefers-reduced-motion:reduce){.zz1,.zz2{animation:none}}
</style></head><body><main><div class="card">
<svg class="ill" viewBox="0 0 200 170" role="img" aria-label="Телевизор спокойно отдыхает">
<circle class="blob" cx="100" cy="92" r="76"/>
<path class="ln" d="M80 30l20 18M120 30l-20 18"/>
<circle class="tvd" cx="80" cy="29" r="5"/><circle class="tvd" cx="120" cy="29" r="5"/>
<path class="ln" d="M70 140l-8 16M130 140l8 16"/>
<rect class="tv" x="36" y="48" width="128" height="94" rx="22"/>
<rect class="scr" x="50" y="61" width="100" height="68" rx="14"/>
<path class="face" d="M74 92q7 6 14 0M112 92q7 6 14 0M90 108q10 8 20 0"/>
<circle class="cheek" cx="72" cy="104" r="6"/><circle class="cheek" cx="128" cy="104" r="6"/>
<text class="zz zz1" x="152" y="40">z</text><text class="zz zz2" x="166" y="24" style="font-size:14px">z</text>
</svg>
<h1>Доступ к этому сайту ограничен</h1>
<p class="lead">На роутере включена <b>блокировка соединений без VPN</b>.</p>
<p class="soft">Такая страница появляется при сбое VPN или во время проверки блокировки.</p>

<div class="box ok">
<h2><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M7.5 12.5l3 3 6-6"/></svg>Какие сайты можно открыть</h2>
<p>Сайты с прямым маршрутом по-прежнему доступны через провайдера. Изображения или видео могут не загрузиться, если им нужен VPN.</p>
</div>

<div class="box calm">
<p><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3a9 9 0 1 0 9 9"/><path d="M12 7v5l3 2"/></svg>Когда роутер восстановит маршрут через VPN, <b>обновите страницу</b>. Перезагрузка устройства не требуется.</p>
</div>

<div class="box help">
<h2><svg class="ic" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8l-4 3v-3H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z"/></svg>К кому обратиться</h2>
<div class="who">$c</div>
</div>

<small>Эту страницу показывает домашний роутер</small>
</div></main></body></html>
EOF
}

