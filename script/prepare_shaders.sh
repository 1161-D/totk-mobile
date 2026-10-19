#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
./script/prepare_shader_tools.sh
work/venv/bin/python script/extract_shaders.py
work/venv/bin/python script/index_shaders.py
work/venv/bin/python script/translate_shaders.py
work/venv/bin/python script/build_shaders.py
