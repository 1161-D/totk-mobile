#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/tmp work/logs
export TMPDIR="$PWD/work/tmp/"
export PYTHONDONTWRITEBYTECODE=1
PYTHON=${PYTHON:-python3.14}
test -x work/venv/bin/python || "$PYTHON" -m venv work/venv
py="$PWD/work/venv/bin/python"
"$py" -c 'from importlib.metadata import version; assert version("capstone") == "5.0.9" and version("lz4") == "4.4.5"' 2>/dev/null || \
    "$py" -m pip install --no-cache-dir --disable-pip-version-check -r requirements/runtime.txt
package=${1:-}
if [[ -z "$package" ]]; then
    package=$("$py" -c 'import sys; from pathlib import Path; sys.path.insert(0, "script"); from game_inputs import game_package; print(game_package(Path("."), True))')
fi
"$py" tools/extract_exefs.py "$package" work/exefs
"$py" tools/prepare_modules.py
