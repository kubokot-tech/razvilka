#!/bin/sh
# Keenetic пересобирает iptables при изменениях — возвращаем правила kill switch, если он активен
[ "$type" = "ip6tables" ] && exit 0
case "$table" in filter|nat) ;; *) exit 0 ;; esac
[ -x /opt/razvilka/razvilka.sh ] && /opt/razvilka/razvilka.sh netfilter
exit 0
