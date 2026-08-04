# build.ps1 - Windows PowerShell Build Script
#
# This script automates the process of building and running the Docker container
# with version information dynamically injected at build time.
#
# It can be invoked from any working directory: the Compose file is located
# relative to this script, and the Compose project directory is pinned to the
# repository root so relative volume paths (./config.yaml, ./auths, ./logs,
# ./plugins) keep resolving there.

# Stop script execution on any error
$ErrorActionPreference = "Stop"

$ScriptDir   = $PSScriptRoot
$RepoRoot    = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$ComposeFile = Join-Path $ScriptDir "docker-compose.yml"

# Use the automatic $args variable instead of a param() block. A declared
# parameter turns this into an advanced function, which makes PowerShell bind
# common parameters first: "-d" would be swallowed as the -Debug alias and never
# reach docker compose, silently dropping detached mode.
#
# The exit code is checked explicitly because $ErrorActionPreference = "Stop"
# does not cover native commands on Windows PowerShell 5.1. Without this the
# script would fall through from a failed "compose build" into "up -d" and try
# to start an image that was never produced.
function Invoke-Compose {
    docker compose -f $ComposeFile --project-directory $RepoRoot @args
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose $($args -join ' ') failed with exit code $LASTEXITCODE"
    }
}

# --- Step 1: Choose Environment ---
Write-Host "Please select an option:"
Write-Host "1) Run using Pre-built Image (Recommended)"
Write-Host "2) Build from Source and Run (For Developers)"
$choice = Read-Host -Prompt "Enter choice [1-2]"

# --- Step 2: Execute based on choice ---
switch ($choice) {
    "1" {
        Write-Host "--- Running with Pre-built Image ---"
        Invoke-Compose up -d --remove-orphans --no-build
        Write-Host "Services are starting from remote image."
        Write-Host "Run 'docker compose -f $ComposeFile logs -f' to see the logs."
    }
    "2" {
        Write-Host "--- Building from Source and Running ---"

        # Get Version Information
        $VERSION = (git -C $RepoRoot describe --tags --always --dirty)
        $COMMIT  = (git -C $RepoRoot rev-parse --short HEAD)
        $BUILD_DATE = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

        Write-Host "Building with the following info:"
        Write-Host "  Version: $VERSION"
        Write-Host "  Commit: $COMMIT"
        Write-Host "  Build Date: $BUILD_DATE"
        Write-Host "----------------------------------------"

        # Build and start the services with a local-only image tag
        $env:CLI_PROXY_IMAGE = "cli-proxy-api:local"

        Write-Host "Building the Docker image..."
        Invoke-Compose build --build-arg VERSION=$VERSION --build-arg COMMIT=$COMMIT --build-arg BUILD_DATE=$BUILD_DATE

        Write-Host "Starting the services..."
        Invoke-Compose up -d --remove-orphans --pull never

        Write-Host "Build complete. Services are starting."
        Write-Host "Run 'docker compose -f $ComposeFile logs -f' to see the logs."
    }
    default {
        Write-Host "Invalid choice. Please enter 1 or 2."
        exit 1
    }
}
