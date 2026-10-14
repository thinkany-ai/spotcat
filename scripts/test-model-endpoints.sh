#!/bin/bash
# Exercises the real endpoint builder without network calls or persisted settings.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$PWD/.build/model-endpoint-tests"
mkdir -p "$TEST_DIR"
swiftc Sources/Spotcat/ModelsConfig.swift Tests/ModelEndpoints/main.swift -o "$TEST_DIR/test-model-endpoints"
"$TEST_DIR/test-model-endpoints"
