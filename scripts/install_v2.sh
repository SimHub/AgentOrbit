#!/usr/bin/env bash
set -euo pipefail

# Cross-platform local-from-source installer for AgentOrbit v2 (macOS & Linux).
# Builds locally with Cargo — zero Apple Developer signing or App Store required.

INSTALL_DIR="${AGENTORBIT_INSTALL_DIR:-$HOME/.local/bin}"
OPEN_AFTER=false

for arg in "$@"; do
  case "$arg" in
    --open) OPEN_AFTER=true ;;
    --dir=*) INSTALL_DIR="${arg#*=}" ;;
  esac
done

echo "Building AgentOrbit v2 release binaries (agentorbit-app + agentorbit CLI)..."
cargo build --release -p agentorbit-app -p agentorbit-cli

mkdir -p "$INSTALL_DIR"
cp target/release/agentorbit-app "$INSTALL_DIR/agentorbit-app"
cp target/release/agentorbit "$INSTALL_DIR/agentorbit"
chmod +x "$INSTALL_DIR/agentorbit-app" "$INSTALL_DIR/agentorbit"

echo "Installed to: $INSTALL_DIR"
echo "  - $INSTALL_DIR/agentorbit-app  (Desktop HUD + System Tray)"
echo "  - $INSTALL_DIR/agentorbit      (CLI: scan / scan --json / watch)"

if [[ "$OPEN_AFTER" == "true" ]]; then
  nohup "$INSTALL_DIR/agentorbit-app" >/dev/null 2>&1 &
  echo "AgentOrbit v2 launched in background."
fi
