#!/usr/bin/env zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: zsh scripts/package_dmg.sh <AgentOrbit.app> <output.dmg>" >&2
  exit 1
fi

APP_BUNDLE="${1:A}"
DMG_PATH="${2:A}"
if [[ ! -d "$APP_BUNDLE" || "${APP_BUNDLE:t}" != AgentOrbit.app ]]; then
  echo "Expected an existing AgentOrbit.app bundle: $APP_BUNDLE" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_BUNDLE"

DMG_WORK="$(mktemp -d /tmp/agentorbit-dmg.XXXXXX)"
export TMPDIR="$DMG_WORK"
DMG_STAGING="$DMG_WORK/staging"
DMG_CANDIDATE="$DMG_WORK/AgentOrbit.dmg"
DMG_ATTACH_INFO="$DMG_WORK/attach.plist"
DMG_DEVICE=""
DMG_OUTPUT_TMP=""

cleanup_dmg() {
  if [[ -n "$DMG_DEVICE" ]]; then
    hdiutil detach "$DMG_DEVICE" >/dev/null || return
  fi
  if [[ -n "$DMG_OUTPUT_TMP" ]]; then
    rm -f "$DMG_OUTPUT_TMP"
  fi
  rm -rf "$DMG_WORK"
}
trap cleanup_dmg EXIT

echo "Packaging DMG..."
mkdir "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "AgentOrbit" -srcfolder "$DMG_STAGING" -fs APFS -format UDZO "$DMG_CANDIDATE" >/dev/null

echo "Verifying app signature inside the DMG..."
hdiutil attach "$DMG_CANDIDATE" -readonly -nobrowse -noautoopen -plist > "$DMG_ATTACH_INFO"
DMG_DEVICE="$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$DMG_ATTACH_INFO")"

DMG_MOUNT=""
entity=0
while /usr/libexec/PlistBuddy -c "Print :system-entities:$entity" "$DMG_ATTACH_INFO" >/dev/null 2>&1; do
  if mount_path="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$entity:mount-point" "$DMG_ATTACH_INFO" 2>/dev/null)" &&
    [[ -d "$mount_path/AgentOrbit.app" ]]; then
    DMG_MOUNT="$mount_path"
    break
  fi
  entity=$((entity + 1))
done
if [[ -z "$DMG_MOUNT" ]]; then
  echo "Could not find AgentOrbit.app on the mounted disk image." >&2
  exit 1
fi
codesign --verify --deep --strict "$DMG_MOUNT/AgentOrbit.app"
hdiutil detach "$DMG_DEVICE" >/dev/null
DMG_DEVICE=""

# The image was created on the system disk. Stage the replacement on the destination volume.
DMG_OUTPUT_TMP="$(mktemp "${DMG_PATH:h}/.agentorbit-dmg.XXXXXX")"
cp "$DMG_CANDIDATE" "$DMG_OUTPUT_TMP"
chmod 644 "$DMG_OUTPUT_TMP"
mv -f "$DMG_OUTPUT_TMP" "$DMG_PATH"
DMG_OUTPUT_TMP=""
echo "Built DMG: $DMG_PATH"
