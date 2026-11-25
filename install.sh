#!/bin/zsh
# Builds CalFeed.app into ~/Applications and runs it at login via launchd.
#
#   ./install.sh               install / update (port 8765)
#   PORT=9000 ./install.sh     use another port
#   ./install.sh --uninstall   remove everything
set -euo pipefail

APP="$HOME/Applications/CalFeed.app"
LABEL="local.calfeed"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/CalFeed.log"
PORT="${PORT:-8765}"
SRC="${0:A:h}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$APP" "$AGENT"
  echo "CalFeed removed. (Calendar permission can be cleared with: tccutil reset Calendar io.github.marceltov.calfeed)"
  exit 0
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use. Pick another: PORT=9000 ./install.sh"; exit 1
fi

mkdir -p "${APP:h}" "$HOME/Library/LaunchAgents" "${LOG:h}"
"$SRC/scripts/build-app.sh" "${APP:h}" >/dev/null

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/CalFeed</string><string>--port</string><string>$PORT</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed. Allow calendar access if macOS asks, then open http://localhost:$PORT/"
open "http://localhost:$PORT/" 2>/dev/null || true
