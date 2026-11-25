#!/bin/sh
set -e
cd "$(dirname "$0")/.."
sh tests/monolith.sh
for f in setup.sh install.sh build.sh src/lib/*.sh src/razvilka.sh src/www/*.sh src/init/* src/cron-*; do
    sh -n "$f"
done
bash tests/routing.sh
bash tests/cgi.sh
sh tests/backup.sh
bash tests/installer.sh
sh tests/dist.sh
echo 'All tests passed'
