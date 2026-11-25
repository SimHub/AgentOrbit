#!/usr/bin/env zsh
set -euo pipefail

UNIVERSAL=false
CREATE_DMG=false

for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --dmg) CREATE_DMG=true ;;
    -h|--help)
      echo "Usage: ./scripts/build_app.sh [--universal] [--dmg]"
      echo "  --universal  Build arm64 + x86_64 fat binary via lipo (default: host arch only)"
      echo "  --dmg        Package dist/AgentOrbit.dmg with Applications symlink"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUILD="$BUILD_DIR/app"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/AgentOrbit.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

SDK_PATH="$(xcrun --show-sdk-path)"
MODULE_CACHE="$BUILD_DIR/module-cache"
HOST_ARCH="$(uname -m)"

mkdir -p "$APP_BUILD" "$MODULE_CACHE" "$BUILD_DIR/tmp" "$DIST_DIR"
export TMPDIR="$BUILD_DIR/tmp"

CORE_SOURCES=("$PROJECT_DIR"/Sources/AgentOrbitCore/**/*.swift)
APP_SOURCES=("$PROJECT_DIR"/Sources/AgentOrbit/**/*.swift "$PROJECT_DIR"/Sources/AgentOrbit/*.swift)
APP_SOURCES=(${(u)APP_SOURCES})

compile_arch() {
  local arch="$1"
  local target="${arch}-apple-macosx14.0"
  local arch_core="$BUILD_DIR/core-${arch}"
  local arch_app="$BUILD_DIR/app-${arch}"
  mkdir -p "$arch_core" "$arch_app"

  echo "1/4 Compiling AgentOrbitCore (${arch})..."
  swiftc \
    -target "$target" \
    -sdk "$SDK_PATH" \
    -swift-version 6 \
    -O \
    -parse-as-library \
    -enable-testing \
    -module-name AgentOrbitCore \
    -emit-module -emit-module-path "$arch_core/AgentOrbitCore.swiftmodule" \
    -emit-object -o "$arch_core/AgentOrbitCore.o" \
    -whole-module-optimization \
    -module-cache-path "$MODULE_CACHE" \
    "${CORE_SOURCES[@]}"

  echo "2/4 Compiling AgentOrbit (${arch})..."
  swiftc \
    -target "$target" \
    -sdk "$SDK_PATH" \
    -swift-version 6 \
    -O \
    -parse-as-library \
    -I "$arch_core" \
    -module-name AgentOrbit \
    -module-cache-path "$MODULE_CACHE" \
    "$arch_core/AgentOrbitCore.o" \
    "${APP_SOURCES[@]}" \
    -lsqlite3 \
    -framework AppKit \
    -framework SwiftUI \
    -framework CoreServices \
    -framework Combine \
    -framework UserNotifications \
    -framework Carbon \
    -framework ServiceManagement \
    -o "$arch_app/AgentOrbit"
}

if [[ "$UNIVERSAL" == "true" ]]; then
  compile_arch "arm64"
  compile_arch "x86_64"
  echo "Creating universal binary via lipo..."
  lipo -create "$BUILD_DIR/app-arm64/AgentOrbit" "$BUILD_DIR/app-x86_64/AgentOrbit" -output "$APP_BUILD/AgentOrbit"
else
  compile_arch "$HOST_ARCH"
  cp "$BUILD_DIR/app-${HOST_ARCH}/AgentOrbit" "$APP_BUILD/AgentOrbit"
fi

echo "3/4 Packaging AgentOrbit.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$APP_BUILD/AgentOrbit" "$MACOS_DIR/AgentOrbit"
chmod +x "$MACOS_DIR/AgentOrbit"

# Generate Apple-spec AppIcon.icns (with TOC + Retina ic11..ic14 chunks) directly via AppKit
swift -sdk "$SDK_PATH" -module-cache-path "$MODULE_CACHE" - "$RESOURCES_DIR/AppIcon.icns" <<'SWIFT'
import AppKit

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

func renderIcon(px: Int) -> Data? {
    let size = NSSize(width: px, height: px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(origin: .zero, size: size)
    let pad = CGFloat(px) * 0.06
    let bgRect = rect.insetBy(dx: pad, dy: pad)
    let radius = bgRect.width * 0.22
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.20, alpha: 1),
        ending: NSColor(calibratedRed: 0.16, green: 0.23, blue: 0.36, alpha: 1)
    )
    gradient?.draw(in: bgPath, angle: -45)

    NSColor.white.withAlphaComponent(0.15).setStroke()
    bgPath.lineWidth = max(1, CGFloat(px) * 0.015)
    bgPath.stroke()

    let center = NSPoint(x: rect.midX, y: rect.midY)
    let r = bgRect.width * 0.30

    let arc1 = NSBezierPath()
    arc1.lineWidth = max(1.5, CGFloat(px) * 0.055)
    arc1.lineCapStyle = .round
    arc1.appendArc(withCenter: center, radius: r, startAngle: 25, endAngle: 205)
    NSColor.white.withAlphaComponent(0.92).setStroke()
    arc1.stroke()

    let arc2 = NSBezierPath()
    arc2.lineWidth = max(1.5, CGFloat(px) * 0.055)
    arc2.lineCapStyle = .round
    arc2.appendArc(withCenter: center, radius: r, startAngle: 225, endAngle: 355)
    NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.95, alpha: 0.92).setStroke()
    arc2.stroke()

    let coreD = bgRect.width * 0.19
    let coreRect = NSRect(x: center.x - coreD / 2, y: center.y - coreD / 2, width: coreD, height: coreD)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: coreRect).fill()

    let satD = bgRect.width * 0.115
    let sat1 = NSRect(x: center.x + r * 0.52, y: center.y + r * 0.52, width: satD, height: satD)
    NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(ovalIn: sat1).fill()

    let sat2 = NSRect(x: center.x - r * 0.88, y: center.y - r * 0.88, width: satD, height: satD)
    NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.26, alpha: 1).setFill()
    NSBezierPath(ovalIn: sat2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

let chunks: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("icp6", 64),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]

var renderedBySize: [Int: Data] = [:]
var tocEntries = Data()
var body = Data()

for (tag, px) in chunks {
    let png = renderedBySize[px] ?? renderIcon(px: px)
    if let png {
        renderedBySize[px] = png
        let chunkLen = UInt32(8 + png.count)
        tocEntries.append(tag.data(using: .ascii)!)
        appendUInt32BE(&tocEntries, chunkLen)

        body.append(tag.data(using: .ascii)!)
        appendUInt32BE(&body, chunkLen)
        body.append(png)
    }
}

var tocChunk = Data("TOC ".data(using: .ascii)!)
appendUInt32BE(&tocChunk, UInt32(8 + tocEntries.count))
tocChunk.append(tocEntries)

var icns = Data("icns".data(using: .ascii)!)
appendUInt32BE(&icns, UInt32(8 + tocChunk.count + body.count))
icns.append(tocChunk)
icns.append(body)
try icns.write(to: outURL)
SWIFT

BUNDLE_ID="${AGENTORBIT_BUNDLE_ID:-dev.agentorbit.AgentOrbit}"
DEFAULT_VERSION="1.1.0"
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_TAG="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$GIT_TAG" ]]; then
    DEFAULT_VERSION="${GIT_TAG#v}"
  fi
fi
APP_VERSION="${AGENTORBIT_VERSION:-$DEFAULT_VERSION}"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AgentOrbit</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AgentOrbit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "4/4 Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
touch "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Built: $APP_BUNDLE"

if [[ "$CREATE_DMG" == "true" ]]; then
  zsh "$PROJECT_DIR/scripts/package_dmg.sh" "$APP_BUNDLE" "$DIST_DIR/AgentOrbit.dmg"
fi
