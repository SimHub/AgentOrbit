#!/usr/bin/env zsh
set -euo pipefail

REPO_URL="${AGENTORBIT_REPO_URL:-https://github.com/SimHub/AgentOrbit.git}"
DMG_URL="${AGENTORBIT_DMG_URL:-https://github.com/SimHub/AgentOrbit/releases/latest/download/AgentOrbit.dmg}"
FROM_SOURCE=false
UNIVERSAL=false
OPEN_AFTER=false
INSTALL_DIR="${AGENTORBIT_INSTALL_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-source) FROM_SOURCE=true; shift ;;
    --universal) UNIVERSAL=true; shift ;;
    --open) OPEN_AFTER=true; shift ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing path after --dir" >&2
        exit 1
      fi
      INSTALL_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'HELP'
Usage: install.sh [options]

Install AgentOrbit on macOS 14+ from the latest GitHub Release DMG,
or build and install directly from source (ideal for AI agents & devs).

Options:
  --from-source   Run tests and build locally instead of downloading the DMG
  --universal     With --from-source, build arm64 + x86_64 universal binary
  --dir <path>    Install destination (default: /Applications or ~/Applications)
  --open          Launch AgentOrbit.app after installation
  -h, --help      Show this help message
HELP
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "AgentOrbit requires macOS 14 or later." >&2
  exit 1
fi

if [[ -z "$INSTALL_DIR" ]]; then
  if [[ -w "/Applications" ]]; then
    INSTALL_DIR="/Applications"
  else
    INSTALL_DIR="$HOME/Applications"
  fi
fi

mkdir -p "$INSTALL_DIR"
TARGET_APP="$INSTALL_DIR/AgentOrbit.app"

WORK_DIR="$(mktemp -d)"
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" ]] && mount | grep -q "on $MOUNT_POINT "; then
    hdiutil detach "$MOUNT_POINT" -quiet || hdiutil detach "$MOUNT_POINT" -force -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

install_app_bundle() {
  local source_app="$1"
  if [[ ! -d "$source_app" ]]; then
    echo "Expected app bundle not found at: $source_app" >&2
    exit 1
  fi

  if [[ -d "$TARGET_APP" ]]; then
    pkill -x AgentOrbit >/dev/null 2>&1 || true
    rm -rf "$TARGET_APP"
  fi
  ditto "$source_app" "$TARGET_APP"
  xattr -cr "$TARGET_APP" >/dev/null 2>&1 || true

  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$TARGET_APP" >/dev/null 2>&1 || true
  fi

  echo "Installed: $TARGET_APP"
}

if [[ "$FROM_SOURCE" == "true" ]]; then
  if [[ -f "$0" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    LOCAL_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"
  else
    LOCAL_ROOT=""
  fi

  if [[ -f "$LOCAL_ROOT/Package.swift" && -f "$LOCAL_ROOT/scripts/build_app.sh" ]]; then
    SRC_DIR="$LOCAL_ROOT"
  else
    echo "Cloning $REPO_URL..."
    SRC_DIR="$WORK_DIR/AgentOrbit"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
  fi

  (
    cd "$SRC_DIR"
    ./scripts/run_tests.sh
    if [[ "$UNIVERSAL" == "true" ]]; then
      ./scripts/build_app.sh --universal
    else
      ./scripts/build_app.sh
    fi
  )

  install_app_bundle "$SRC_DIR/dist/AgentOrbit.app"
else
  DMG_FILE="$WORK_DIR/AgentOrbit.dmg"
  MOUNT_POINT="$WORK_DIR/mnt"
  mkdir -p "$MOUNT_POINT"

  echo "Downloading latest AgentOrbit.dmg..."
  curl -fL --retry 3 --progress-bar "$DMG_URL" -o "$DMG_FILE"

  echo "Mounting DMG..."
  hdiutil attach "$DMG_FILE" -nobrowse -readonly -mountpoint "$MOUNT_POINT" -quiet

  install_app_bundle "$MOUNT_POINT/AgentOrbit.app"
fi

if [[ "$OPEN_AFTER" == "true" ]]; then
  echo "Launching AgentOrbit..."
  open "$TARGET_APP"
else
  echo "Run: open \"$TARGET_APP\""
fi
