#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${1:-simulator}"
CONFIGURATION="${2:-Debug}"

case "${TARGET}" in
    simulator|sim|device|dev) ;;
    *)
        echo "Usage: $0 [simulator|device] [Debug|Release]" >&2
        exit 2
        ;;
esac

if [[ "${CONFIGURATION}" != "Debug" && "${CONFIGURATION}" != "Release" ]]; then
    echo "Usage: $0 [simulator|device] [Debug|Release]" >&2
    exit 2
fi

# iOS requires a full Xcode developer directory, similar to Android builds needing SDK/NDK paths.
# Override with either DEVELOPER_DIR or XCODE_DEVELOPER_DIR when Xcode is installed elsewhere.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

if [[ ! -x "${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
    echo "Xcode developer directory is invalid: ${DEVELOPER_DIR}" >&2
    echo "Set DEVELOPER_DIR or XCODE_DEVELOPER_DIR to /path/to/Xcode.app/Contents/Developer" >&2
    exit 1
fi

if [[ -z "${VCPKG_ROOT:-}" && -d "${PROJECT_DIR}/../vcpkg" ]]; then
    export VCPKG_ROOT="$(cd "${PROJECT_DIR}/../vcpkg" && pwd)"
fi

if [[ -z "${VCPKG_ROOT:-}" || ! -f "${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" ]]; then
    echo "VCPKG_ROOT is not set and ../vcpkg was not found." >&2
    echo "Set VCPKG_ROOT=/path/to/vcpkg before running this script." >&2
    exit 1
fi

if [[ "${TARGET}" == "simulator" || "${TARGET}" == "sim" ]]; then
    SDK_NAME="iphonesimulator"
    CONFIG_PRESET="iOS Simulator Config"
    BUILD_PRESET="iOS Simulator ${CONFIGURATION} Build"
else
    SDK_NAME="iphoneos"
    CONFIG_PRESET="iOS Device Config"
    BUILD_PRESET="iOS Device ${CONFIGURATION} Build"
fi

SDK_PATH="$(xcrun --sdk "${SDK_NAME}" --show-sdk-path)"

echo "Using DEVELOPER_DIR=${DEVELOPER_DIR}"
echo "Using ${SDK_NAME} SDK=${SDK_PATH}"
echo "Using VCPKG_ROOT=${VCPKG_ROOT}"
echo

cd "${PROJECT_DIR}"

echo "[1/2] Configuring ${CONFIG_PRESET}..."
cmake --preset "${CONFIG_PRESET}" -DUSE_RENDER_VK=OFF
echo

echo "[2/2] Building ${BUILD_PRESET}..."
cmake --build --preset "${BUILD_PRESET}" --parallel
echo
