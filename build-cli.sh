#!/bin/bash
# Text-only launcher. Keep this file next to build-raspap-webone.sh
#   sudo ./build-cli.sh
#   ./build-cli.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/build-raspap-webone.sh"
[[ -f "$SCRIPT" ]] || { printf 'missing %s\n' "$SCRIPT" >&2; exit 1; }
if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SCRIPT" --cli "$@"
fi
exec bash "$SCRIPT" --cli "$@"
