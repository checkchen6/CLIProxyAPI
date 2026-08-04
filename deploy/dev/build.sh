#!/usr/bin/env bash
#
# build.sh - Linux/macOS Build Script
#
# This script automates the process of building and running the Docker container
# with version information dynamically injected at build time.
#
# It can be invoked from any working directory: the Compose file is located
# relative to this script, and the Compose project directory is pinned to the
# repository root so relative volume paths (./config.yaml, ./auths, ./logs,
# ./plugins) keep resolving there.

set -euo pipefail

if [[ "${1:-}" != "" ]]; then
  echo "Error: unknown option '${1}'."
  echo "Usage: ./deploy/dev/build.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

compose() {
  docker compose -f "${COMPOSE_FILE}" --project-directory "${REPO_ROOT}" "$@"
}

# --- Step 1: Choose Environment ---
echo "Please select an option:"
echo "1) Run using Pre-built Image (Recommended)"
echo "2) Build from Source and Run (For Developers)"
read -r -p "Enter choice [1-2]: " choice

# --- Step 2: Execute based on choice ---
case "$choice" in
  1)
    echo "--- Running with Pre-built Image ---"
    compose up -d --remove-orphans --no-build
    echo "Services are starting from remote image."
    echo "Run 'docker compose -f ${COMPOSE_FILE} logs -f' to see the logs."
    ;;
  2)
    echo "--- Building from Source and Running ---"

    # Get Version Information
    VERSION="$(git -C "${REPO_ROOT}" describe --tags --always --dirty)"
    COMMIT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo "Building with the following info:"
    echo "  Version: ${VERSION}"
    echo "  Commit: ${COMMIT}"
    echo "  Build Date: ${BUILD_DATE}"
    echo "----------------------------------------"

    # Build and start the services with a local-only image tag
    export CLI_PROXY_IMAGE="cli-proxy-api:local"

    echo "Building the Docker image..."
    compose build \
      --build-arg VERSION="${VERSION}" \
      --build-arg COMMIT="${COMMIT}" \
      --build-arg BUILD_DATE="${BUILD_DATE}"

    echo "Starting the services..."
    compose up -d --remove-orphans --pull never

    echo "Build complete. Services are starting."
    echo "Run 'docker compose -f ${COMPOSE_FILE} logs -f' to see the logs."
    ;;
  *)
    echo "Invalid choice. Please enter 1 or 2."
    exit 1
    ;;
esac
