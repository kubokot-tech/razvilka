#!/bin/sh
# Установка razvilka на роутер с Mac/Linux одной командой:
#   ./install.sh                       # root@192.168.1.1, SSH Entware на порту 222
#   ./install.sh root@10.0.0.1         # другой роутер
#   ./install.sh root@192.168.1.1 -- --contact "Иван, +7 900 ..." --yes
#   ./install.sh root@192.168.1.1 uninstall
# Порт SSH: переменная PORT (по умолчанию 222 — dropbear Entware).
# Пароль root спросит ssh (или используется ключ).
set -e
cd "$(dirname "$0")"
TARGET=${1:-root@192.168.1.1}; [ $# -gt 0 ] && shift
ACTION=install
[ "${1:-}" = uninstall ] || [ "${1:-}" = status ] && { ACTION=$1; shift; }
[ "${1:-}" = "--" ] && shift
PORT=${PORT:-222}
# одно соединение на все шаги — пароль спрашивается один раз
CTL=/tmp/razvilka-ssh-$$
SSH="ssh -p $PORT -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=120"
trap '$SSH -O exit "$TARGET" >/dev/null 2>&1; rm -f $CTL' EXIT

./build.sh
echo "→ копирую установщик на $TARGET"
$SSH "$TARGET" 'mkdir -p /opt/tmp && cat > /opt/tmp/razvilka-setup.sh' < dist/razvilka-setup.sh
# shell-экранирование аргументов для удалённой стороны
args=""; for a in "$@"; do args="$args '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"; done
echo "→ запускаю: $ACTION"
$SSH -t "$TARGET" "sh /opt/tmp/razvilka-setup.sh $ACTION $args; rc=\$?; rm -f /opt/tmp/razvilka-setup.sh; exit \$rc"
