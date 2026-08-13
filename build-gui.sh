#!/bin/bash
# Graphical launcher. Keep this file next to build-raspap-webone.sh
#   sudo ./build-gui.sh
#   ./build-gui.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/build-raspap-webone.sh"
[[ -f "$SCRIPT" ]] || { printf 'missing %s\n' "$SCRIPT" >&2; exit 1; }
if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SCRIPT" --ui "$@"
fi
exec bash "$SCRIPT" --ui "$@"
