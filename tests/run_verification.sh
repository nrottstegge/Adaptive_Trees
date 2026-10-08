#!/usr/bin/env bash
# Checks both backends and the template Tree wrapper, including captured updates.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_DIR}/build"

cmake -S "${REPO_DIR}" -B "${BUILD_DIR}"
cmake --build "${BUILD_DIR}" -j"$(nproc)" --target tree_test
"${BUILD_DIR}/tests/tree_test" "$@"
