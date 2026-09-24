#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
MODULE_CACHE="/Users/zz/Documents/personal_work/deskday-module-cache"
mkdir -p "$MODULE_CACHE"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 "$BASE/Deskday.swift" -o "/Users/zz/Documents/personal_work/Deskday"
echo "Built /Users/zz/Documents/personal_work/Deskday"
