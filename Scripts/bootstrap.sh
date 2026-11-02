#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEPS="$PWD/.build/deps"
mkdir -p "$DEPS"
verify() {
  printf '%s  %s\n' "$1" "$2" | shasum -a 256 -c -
}

# Build-time downloads only. The application bundles all of these dependencies.
if [ ! -f "$DEPS/onnxruntime/lib/libonnxruntime.1.23.2.dylib" ]; then
  curl --fail --location --retry 3 https://github.com/microsoft/onnxruntime/releases/download/v1.23.2/onnxruntime-osx-arm64-1.23.2.tgz -o "$DEPS/ort.tgz"
  verify b4d513ab2b26f088c66891dbbc1408166708773d7cc4163de7bdca0e9bbb7856 "$DEPS/ort.tgz"
  tar -xzf "$DEPS/ort.tgz" -C "$DEPS"
  mv "$DEPS/onnxruntime-osx-arm64-1.23.2" "$DEPS/onnxruntime"
fi
if [ ! -f "$DEPS/sentencepiece/lib/libsentencepiece.a" ]; then
  curl --fail --location --retry 3 https://codeload.github.com/google/sentencepiece/tar.gz/refs/tags/v0.2.1 -o "$DEPS/sp.tgz"
  verify c1a59e9259c9653ad0ade653dadff074cd31f0a6ff2a11316f67bee4189a8f1b "$DEPS/sp.tgz"
  tar -xzf "$DEPS/sp.tgz" -C "$DEPS"
  cmake -S "$DEPS/sentencepiece-0.2.1" -B "$DEPS/sp-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS/sentencepiece" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DSPM_ENABLE_SHARED=OFF \
    -DSPM_BUILD_TEST=OFF -DSPM_ENABLE_TCMALLOC=OFF
  cmake --build "$DEPS/sp-build" --target sentencepiece-static -j 6
  mkdir -p "$DEPS/sentencepiece/lib" "$DEPS/sentencepiece/include"
  cp "$DEPS/sp-build/src/libsentencepiece.a" "$DEPS/sentencepiece/lib/"
  cp "$DEPS/sentencepiece-0.2.1/src/sentencepiece_processor.h" "$DEPS/sentencepiece/include/"
fi
if [ ! -f "$DEPS/include/nlohmann/json.hpp" ]; then
  mkdir -p "$DEPS/include/nlohmann"
  curl --fail --location --retry 3 https://raw.githubusercontent.com/nlohmann/json/v3.12.0/single_include/nlohmann/json.hpp -o "$DEPS/include/nlohmann/json.hpp"
  verify aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63 "$DEPS/include/nlohmann/json.hpp"
fi
echo "Native dependencies are ready."
