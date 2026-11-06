#!/bin/sh
# Build the app (Debug by default) and put it at .build/Miles.app.
set -eu
cd "$(dirname "$0")/.."
config="${1:-Debug}"
derived=".build/xcode"
xcodebuild -project Miles.xcodeproj -scheme MilesApp -configuration "$config" \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
rm -rf .build/Miles.app
ditto "$derived/Build/Products/$config/Miles.app" .build/Miles.app
echo "App: $(pwd)/.build/Miles.app"
