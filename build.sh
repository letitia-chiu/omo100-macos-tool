#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="${PWD}/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="${PWD}/.build/module-cache"
swiftc OMO100Tool.swift \
  -module-cache-path "${PWD}/.build/module-cache" \
  -framework IOKit \
  -framework CoreGraphics \
  -framework ImageIO \
  -o omo100-tool

echo "Built: ${PWD}/omo100-tool"
