#!/bin/sh
# Авторизованное скачивание резервной копии настроек.
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin HOME=/opt/root
DIR=${RZ_TEST_DIR:-/opt/razvilka}
[ "$REQUEST_METHOD" = GET ] || { printf 'Status: 405 Method Not Allowed\r\nAllow: GET\r\n\r\n'; exit 0; }
[ -n "${REMOTE_USER:-}" ] || { printf 'Status: 403 Forbidden\r\nCache-Control: no-store\r\n\r\n'; exit 0; }
f=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^f=//p' | head -1)
case "$f" in *[!A-Za-z0-9._-]*) printf 'Status: 404 Not Found\r\n\r\n'; exit 0 ;; backup-*.tar.gz) ;; *) printf 'Status: 404 Not Found\r\n\r\n'; exit 0 ;; esac
file=$DIR/backups/$f
[ -f "$file" ] && [ ! -L "$file" ] || { printf 'Status: 404 Not Found\r\n\r\n'; exit 0; }
printf 'Content-Type: application/gzip\r\nContent-Disposition: attachment; filename="%s"\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Length: %s\r\n\r\n' "$f" "$(wc -c < "$file")"
cat "$file"
