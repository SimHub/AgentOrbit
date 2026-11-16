#!/usr/bin/env zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
CORE_BUILD="$BUILD_DIR/core"
TEST_BUILD="$BUILD_DIR/tests"
SDK_PATH="$(xcrun --show-sdk-path)"
HOST_ARCH="$(uname -m)"
TARGET_TRIPLE="${HOST_ARCH}-apple-macosx14.0"
MODULE_CACHE="$BUILD_DIR/module-cache"

mkdir -p "$CORE_BUILD" "$TEST_BUILD" "$MODULE_CACHE" "$BUILD_DIR/tmp"
export TMPDIR="$BUILD_DIR/tmp"

CORE_SOURCES=("$PROJECT_DIR"/Sources/AgentOrbitCore/**/*.swift)
swiftc \
  -target "$TARGET_TRIPLE" \
  -sdk "$SDK_PATH" \
  -swift-version 6 \
  -parse-as-library \
  -enable-testing \
  -module-name AgentOrbitCore \
  -emit-module -emit-module-path "$CORE_BUILD/AgentOrbitCore.swiftmodule" \
  -emit-object -o "$CORE_BUILD/AgentOrbitCore.o" \
  -whole-module-optimization \
  -module-cache-path "$MODULE_CACHE" \
  "${CORE_SOURCES[@]}"

swiftc \
  -target "$TARGET_TRIPLE" \
  -sdk "$SDK_PATH" \
  -swift-version 6 \
  -parse-as-library \
  -I "$CORE_BUILD" \
  -module-cache-path "$MODULE_CACHE" \
  "$CORE_BUILD/AgentOrbitCore.o" \
  "$PROJECT_DIR/Tests/AgentOrbitTests/ReaderTests.swift" \
  -lsqlite3 \
  -framework AppKit \
  -framework CoreServices \
  -framework Combine \
  -o "$TEST_BUILD/AgentOrbitTests"

"$TEST_BUILD/AgentOrbitTests"
