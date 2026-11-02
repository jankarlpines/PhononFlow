#!/bin/bash
# One-time setup: installs Phonon-2 (Fermion Research) into ./.venv, then builds the app.
set -euo pipefail
cd "$(dirname "$0")"
command -v uv >/dev/null || { echo "Install uv first: brew install uv"; exit 1; }
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "fermion-research[mlx]"
./build.sh
echo "Done. Open ~/Applications/PhononFlow.app (the model downloads ~160 MB on first launch)."
