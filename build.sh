#!/bin/bash
# ?? macOS ?????? Mac??? GitHub Actions?
set -e
APP=build/Payload/SandboxScanner.app
rm -rf build SandboxScanner.ipa
mkdir -p "$APP"

xcrun --sdk iphoneos swiftc \
  -target arm64-apple-ios14.0 \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -O -module-name SandboxScanner -emit-executable \
  -o "$APP/SandboxScanner" \
  Sources/main.swift Sources/AppDelegate.swift Sources/ViewController.swift

cp Info.plist "$APP/Info.plist"
chmod +x "$APP/SandboxScanner"

ldid -S SandboxScanner.entitlements "$APP/SandboxScanner"

cd build && zip -qry ../SandboxScanner.ipa Payload && cd ..
echo "OK: SandboxScanner.ipa"
shasum -a 256 SandboxScanner.ipa