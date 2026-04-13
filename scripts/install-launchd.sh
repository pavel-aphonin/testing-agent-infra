#!/usr/bin/env bash
# Install Markov host services as macOS LaunchAgents.
# After installation, services start automatically on login.
# No more `make start` needed.
#
# Usage:
#   ./scripts/install-launchd.sh    # install + start
#   ./scripts/install-launchd.sh remove  # remove

set -euo pipefail
cd "$(dirname "$0")/.."

PLIST_DIR="$HOME/Library/LaunchAgents"
INFRA_DIR="$(pwd)"

if [[ "${1:-}" == "remove" ]]; then
  echo "Removing Markov launch agents..."
  for name in com.markov.worker com.markov.llm-chat com.markov.llm-embed; do
    launchctl unload "$PLIST_DIR/$name.plist" 2>/dev/null || true
    rm -f "$PLIST_DIR/$name.plist"
    echo "  ✓ $name removed"
  done
  echo "Done."
  exit 0
fi

mkdir -p "$PLIST_DIR"

echo "Installing Markov launch agents..."

# Worker
cat > "$PLIST_DIR/com.markov.worker.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.markov.worker</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INFRA_DIR/scripts/start-host-services.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>/tmp/markov-launchd.log</string>
  <key>StandardErrorPath</key><string>/tmp/markov-launchd.log</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_DIR/com.markov.worker.plist"
echo "  ✓ com.markov.worker installed (starts on login)"

echo ""
echo "Done. Services will start automatically on login."
echo "To remove: $0 remove"
