# Render a page of the retained log. Only approved summaries enter the public feed.
BEGIN {
    limit = public_view ? 8 : 25
    path = public_view ? "/status" : "/admin"
    if (cursor !~ /^[0-9]+$/ || length(cursor) > 9) cursor = 0
    cursor += 0
}

function escape_html(text) {
    gsub(/&/, "\\&amp;", text)
    gsub(/</, "\\&lt;", text)
    gsub(/>/, "\\&gt;", text)
    return text
}

function public_summary(msg) {
    if (msg == "VPN не отвечает" || msg ~ /^туннель не отвечает/) return "VPN не отвечает"
    if (msg == "Связь с VPN восстановлена" || msg ~ /^туннель жив/) return "Связь с VPN восстановлена"
    if (msg == "kill switch: soft" || msg ~ /^KILL SWITCH ВКЛ \(мягкий/) return "Включена блокировка с исключениями"
    if (msg ~ /^kill switch: (kill|direct)$/ || msg ~ /^KILL SWITCH ВКЛ/) return "Включена блокировка зарубежных адресов"
    if (msg == "kill switch выкл" || msg ~ /^KILL SWITCH ВЫКЛ/) return "Блокировка снята"
    if (msg == "режим при падении VPN: direct") return "При сбое VPN разрешён выход через провайдера"
    if (msg == "режим при падении VPN: soft") return "При сбое VPN включится блокировка с исключениями"
    if (msg == "режим при падении VPN: kill") return "При сбое VPN зарубежные адреса будут заблокированы"
    if (msg ~ /^тест kill switch на [0-9]+ мин$/) return "Началась проверка блокировки"
    if (msg == "тест kill switch остановлен") return "Проверка блокировки завершена"
    return ""
}

function severity(msg, summary) {
    if (summary == "VPN не отвечает") return "error"
    if (summary ~ /^Включена блокировка/) return "warn"
    if (summary == "Связь с VPN восстановлена" || summary == "Блокировка снята") return "ok"
    if (msg ~ /ошибк|не удалось|не найд(е|ё)н|не наш(е|ё)л|не прошли проверку|нет (адресов|шлюза|интерфейса)|занят чужим правилом|отсутствуют обязательные настройки|VPN_RESTART не задан/) return "error"
    if (msg ~ /жду туннель|список РФ недоступен|подозрительно мало|другая операция ещё выполняется|не вернул подсетей|не собрался ipset|прежние настройки возвращены/) return "warn"
    return "info"
}

{
    msg = $0
    stamp = ""
    if ($1 ~ /^[0-9-]+$/ && length($1) == 10 && $2 ~ /^[0-9:]+$/ && length($2) == 8) {
        stamp = $1 " " $2
        sub(/^[^ ]+ [^ ]+ /, "", msg)
    }
    summary = public_summary(msg)
    if (public_view && (!length(summary) || !length(stamp))) next
    count++
    if (cursor && count > cursor) next
    # Keep only the displayed page in memory, even when a file is growing.
    slot = count % limit
    level[slot] = severity(msg, summary)
    # These terse state markers have no additional diagnostic details.
    if (public_view || msg == "kill switch выкл" || msg ~ /^kill switch: (soft|kill|direct)$/) msg = summary
    message[slot] = msg
    timestamp[slot] = stamp
}

END {
    if (!count) {
        print "<p class=\"journal-empty\">" (public_view ? "Событий пока нет." : "Журнал пока пуст.") "</p>"
        exit
    }
    high = cursor && cursor < count ? cursor : count
    low = high > limit ? high - limit + 1 : 1
    print "<ol class=\"journal-list\" tabindex=\"0\" aria-label=\"Сначала новые записи\">"
    for (i = high; i >= low; i--) {
        slot = i % limit
        kind = level[slot]
        printf "<li class=\"entry %s\"><div class=\"entry-meta\">", kind
        if (length(timestamp[slot])) printf "<time>%s</time>", timestamp[slot]
        if (kind != "info") {
            label = kind == "error" ? "Ошибка" : (kind == "warn" ? "Внимание" : "Норма")
            printf "<strong class=\"entry-level\">%s</strong>", label
        }
        printf "</div><span class=\"entry-message\">%s</span></li>\n", escape_html(message[slot])
    }
    print "</ol>"
    if (count > limit) {
        print "<nav class=\"journal-pages\" aria-label=\"Страницы журнала\">"
        printf "<span>Записи %d–%d из %d</span>", low, high, count
        if (high < count) {
            newer = high + limit
            printf "<a href=\"%s%s#journal\">Новее</a>", path, (newer >= count ? "" : "?log_end=" newer)
        }
        if (low > 1) printf "<a href=\"%s?log_end=%d#journal\">Раньше</a>", path, low - 1
        print "</nav>"
    }
}
