#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/bootstrap.sh
DEPS="$PWD/.build/deps"
clang++ -std=c++17 -O2 -mmacosx-version-min=26.0 \
  -I Native/include -I "$DEPS/onnxruntime/include" -I "$DEPS/sentencepiece/include" -I "$DEPS/include" \
  Native/RonaSpeech.cpp NativeTests/RuntimeTests.cpp "$DEPS/sentencepiece/lib/libsentencepiece.a" \
  -L "$DEPS/onnxruntime/lib" -lonnxruntime -Wl,-rpath,"$DEPS/onnxruntime/lib" -o .build/native-tests
.build/native-tests "$PWD/YaraVoice_bundle"
