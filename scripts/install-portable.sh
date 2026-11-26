#!/usr/bin/env bash
set -euo pipefail

# Installs portable AgentOrbit v2 binaries into ~/.local/bin and registers
# a native app launcher for macOS Spotlight or Linux app search (GNOME/KDE/Rofi).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${AGENTORBIT_INSTALL_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/agentorbit-app" "$INSTALL_DIR/agentorbit-app"
cp "$SCRIPT_DIR/agentorbit" "$INSTALL_DIR/agentorbit"
chmod +x "$INSTALL_DIR/agentorbit-app" "$INSTALL_DIR/agentorbit"

echo "Installed binaries to: $INSTALL_DIR"

if [[ "$(uname -s)" == "Darwin" ]]; then
  APP_DIR="$HOME/Applications/AgentOrbit.app"
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  cat > "$APP_DIR/Contents/MacOS/AgentOrbit" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/agentorbit-app" "\$@"
EOF
  chmod +x "$APP_DIR/Contents/MacOS/AgentOrbit"
  if [[ -f "$SCRIPT_DIR/icon.png" ]]; then
    cp "$SCRIPT_DIR/icon.png" "$APP_DIR/Contents/Resources/icon.png"
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
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
  echo "Registered macOS Spotlight launcher: $APP_DIR"
elif [[ "$(uname -s)" == "Linux" ]]; then
  ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
  DESKTOP_DIR="$HOME/.local/share/applications"
  mkdir -p "$ICON_DIR" "$DESKTOP_DIR"
  if [[ -f "$SCRIPT_DIR/icon.png" ]]; then
    cp "$SCRIPT_DIR/icon.png" "$ICON_DIR/agentorbit.png"
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
  echo "Registered Linux app launcher: $DESKTOP_DIR/agentorbit.desktop"
fi
