#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/bootstrap.sh
xcodegen generate
xcodebuild -project RonaVoice.xcodeproj -scheme RonaVoice -configuration Release \
  -derivedDataPath .build/Xcode -destination 'platform=macOS,arch=arm64' build
mkdir -p build
ditto .build/Xcode/Build/Products/Release/RonaVoice.app "build/Rona Voice.app"
echo "Built: $PWD/build/Rona Voice.app"
