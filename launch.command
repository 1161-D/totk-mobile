#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/work/build/Zelda-Mobile.app"
if [[ ! -x "$app/Contents/MacOS/launch" ]]; then
    echo 'Game build not found. Run ./script/build_and_run.sh --load-only from the project directory first.' >&2
    exit 1
fi
if pgrep -x zelda_probe >/dev/null; then
    exec open "$app"
fi
exec "$app/Contents/MacOS/launch"
