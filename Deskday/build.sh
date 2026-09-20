#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$BASE/Deskday.app/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 "$BASE/Deskday.swift" -o "$BASE/Deskday.app/Contents/MacOS/Deskday"
codesign --force --deep --sign - "$BASE/Deskday.app"
codesign --verify --deep --strict "$BASE/Deskday.app"
