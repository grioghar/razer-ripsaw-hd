#!/bin/zsh
# Builds Ripsaw HD Viewer.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Ripsaw HD Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/RipsawHDViewer" Sources/main.swift
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built: $APP"
