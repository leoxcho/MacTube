#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ICON="$ROOT/SmartTubeApp/SmartTubeApp/Assets.xcassets/MacTubeIcon.appiconset/mactube-1024.png"

APP="${1:-$HOME/Applications/MacTube.app}"

swift "$ROOT/scripts/apply-mactube-icon.swift" "$ICON" "$APP"

touch "$APP"

echo "MacTube full-size icon preserved: $APP"
