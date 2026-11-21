#!/bin/bash
# 构建 HokkaidoSnowSaver.app（无需 Xcode 工程，仅依赖 Xcode Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HokkaidoSnowSaver"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Lyrics"

echo "==> 编译 main.swift"
swiftc -O -framework AppKit -framework SwiftUI \
    main.swift \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> 写入 Info.plist"
cp Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> Ad-hoc 签名"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "完成：$(pwd)/$APP_DIR"
du -sh "$APP_DIR"
