#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

swift run MiSensorCoreTests

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -typecheck -parse-as-library \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos14.0 \
  -swift-version 6 \
  Sources/MiSensorCore/*.swift Sources/MiSensorApp/*.swift

xcrun swiftc -typecheck -parse-as-library \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos14.0 \
  -swift-version 6 \
  Sources/MiSensorCore/SensorReading.swift Sources/MiSensorWidget/*.swift

plutil -lint \
  Sources/MiSensorApp/Info.plist \
  Sources/MiSensorApp/MiSensorApp.entitlements \
  Sources/MiSensorWidget/Info.plist \
  Sources/MiSensorWidget/MiSensorWidget.entitlements \
  MiSensor.xcodeproj/project.pbxproj

printf '%s\n' 'PASS: app and widget type checks; plist validation'
