#!/bin/sh
# Скачивание текущего журнала из панели управления.
logfile=${RZ_TEST_LOG:-/opt/var/log/razvilka.log}
[ "${REQUEST_METHOD:-}" = GET ] || { printf 'Status: 405 Method Not Allowed\r\nAllow: GET\r\n\r\n'; exit 0; }
[ -n "${REMOTE_USER:-}" ] || { printf 'Status: 403 Forbidden\r\nCache-Control: no-store\r\n\r\n'; exit 0; }
if [ -f "$logfile" ] && [ ! -L "$logfile" ]; then
    {
        printf 'Content-Type: text/plain; charset=utf-8\r\nContent-Disposition: attachment; filename="razvilka.log"\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
        cat
        exit $?
    } < "$logfile"
fi
printf 'Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\nЖурнал пока недоступен.\n'
