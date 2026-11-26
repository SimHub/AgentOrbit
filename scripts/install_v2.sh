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
echo "  - $INSTALL_DIR/agentorbit      (CLI & Glass-HUD TUI: agentorbit tui)"

# On macOS, create a lightweight local Spotlight/Launchpad launcher in ~/Applications
# (zero Apple signing or quarantine because it is created locally).
if [[ "$(uname -s)" == "Darwin" ]]; then
  APP_DIR="$HOME/Applications/AgentOrbit.app"
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  cat > "$APP_DIR/Contents/MacOS/AgentOrbit" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/agentorbit-app" "\$@"
EOF
  chmod +x "$APP_DIR/Contents/MacOS/AgentOrbit"
  if [[ -f "dist/AgentOrbit.app/Contents/Resources/AppIcon.icns" ]]; then
    cp "dist/AgentOrbit.app/Contents/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  elif [[ -f "src-tauri/icons/icon.png" ]]; then
    cp "src-tauri/icons/icon.png" "$APP_DIR/Contents/Resources/icon.png"
  fi
  cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentOrbit</string>
  <key>CFBundleDisplayName</key><string>AgentOrbit</string>
  <key>CFBundleIdentifier</key><string>dev.agentorbit.AgentOrbit</string>
  <key>CFBundleVersion</key><string>2.0.1</string>
  <key>CFBundleShortVersionString</key><string>2.0.1</string>
  <key>CFBundleExecutable</key><string>AgentOrbit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
  echo "  - $APP_DIR  (macOS Spotlight / Launchpad launcher)"
elif [[ "$(uname -s)" == "Linux" ]]; then
  ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
  DESKTOP_DIR="$HOME/.local/share/applications"
  mkdir -p "$ICON_DIR" "$DESKTOP_DIR"
  if [[ -f "src-tauri/icons/icon.png" ]]; then
    cp "src-tauri/icons/icon.png" "$ICON_DIR/agentorbit.png"
  fi
  cat > "$DESKTOP_DIR/agentorbit.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AgentOrbit
Comment=Live Desktop HUD for AI Coding Agents
Exec=$INSTALL_DIR/agentorbit-app
Icon=agentorbit
Terminal=false
Categories=Development;Utility;
EOF
  echo "  - $DESKTOP_DIR/agentorbit.desktop  (Linux app search / launcher)"
fi

if [[ "$OPEN_AFTER" == "true" ]]; then
  nohup "$INSTALL_DIR/agentorbit-app" >/dev/null 2>&1 &
  echo "AgentOrbit v2 launched in background."
fi
