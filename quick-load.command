#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Reuse the normal launcher's existing-window check; never inject input into a running game.
export ZELDA_INPUT_SCRIPT="$PWD/script/scenes/first-save-fast.input"
exec ./launch.command
