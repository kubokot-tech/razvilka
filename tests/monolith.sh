#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cat src/lib/core.sh src/lib/ipv6.sh src/lib/ai.sh src/lib/devices.sh src/lib/lists.sh src/lib/kill.sh src/lib/web.sh src/lib/neighbors.sh src/lib/backup.sh src/lib/main.sh | cmp - src/razvilka.sh
echo 'Monolith is synchronized with lib modules'
