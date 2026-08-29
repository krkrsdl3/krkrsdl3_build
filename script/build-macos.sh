#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURATION="${1:-Release}"

if [[ "${CONFIGURATION}" != "Debug" && "${CONFIGURATION}" != "Release" ]]; then
    echo "Usage: $0 [Debug|Release]" >&2
    exit 2
fi

if [[ -z "${VCPKG_ROOT:-}" && -d "${PROJECT_DIR}/../vcpkg" ]]; then
    export VCPKG_ROOT="$(cd "${PROJECT_DIR}/../vcpkg" && pwd)"
fi

cd "${PROJECT_DIR}"

echo "[1/2] Configuring macOS CMake..."
cmake --preset "macOS Config" -DUSE_RENDER_VK=OFF
echo

echo "[2/2] Building macOS ${CONFIGURATION} version..."
cmake --build --preset "macOS ${CONFIGURATION} Build" --parallel
echo
