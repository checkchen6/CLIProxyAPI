# build-push.ps1 - Build a private image from this working tree and ship it.
#
# Only needed when you carry local changes. If the working tree matches
# upstream, use the published multi-arch image instead
# (eceasy/cli-proxy-api:<tag>, built by .github/workflows/docker-image.yml on
# every v* tag) and skip this script entirely.
#
# Deliberately NOT introducing a VERSION file: this repository already derives
# its version from git tags (deploy/dev/build.sh uses `git describe`, CI uses
# GITHUB_REF_NAME). A second version source would drift.
#
# Preflight gates, all blocking, mirroring the repo's own contract in AGENTS.md:
#   1. gofmt    - formatting is required after Go changes
#   2. go build - compile verification is required after changes
#   3. BOM scan - a UTF-8 BOM breaks YAML parsing for docker compose
#
# Usage:
#   .\deploy\docker\build-push.ps1                  # build and push :<version> AND :latest (default)
#   .\deploy\docker\build-push.ps1 -NoLatest        # skip the :latest tag
#   .\deploy\docker\build-push.ps1 -Local           # build locally only, do not push
#   .\deploy\docker\build-push.ps1 -Save            # build locally and export a gzipped tar
#   .\deploy\docker\build-push.ps1 -Registry registry.cn-hangzhou.aliyuncs.com -Namespace myns
#   .\deploy\docker\build-push.ps1 -NoCache -Platform linux/arm64

[CmdletBinding()]
param(
    # Build the image locally only, without pushing to a registry. Without this
    # switch the script pushes to the configured registry by default.
    [switch] $Local,

    # Export the image to a gzipped tar for transfer over scp. Useful when there
    # is no registry to go through. Implies local-only (no push).
    [switch] $Save,

    [string] $Registry = "registry.cn-hangzhou.aliyuncs.com",
    [string] $Namespace = "wgyc",
    [string] $Repository = "cli-proxy-api",

    # The server this targets is x86_64. Override for arm64 hosts.
    [string] $Platform = "linux/amd64",

    # Skip the :latest tag. Tagging and pushing :latest is ON by default because
    # deploy.sh defaults to the :latest tag -- if the registry does not carry it,
    # the server-side pull fails with "manifest unknown". Only use this when you
    # deliberately want a build that no default deployment can pick up.
    [switch] $NoLatest,

    [switch] $NoCache,

    # Skip the gofmt / go build gates. For emergencies only.
    [switch] $SkipChecks,

    # Skip rebuilding the embedded web management panel. Use when the working
    # tree already carries a freshly built management.html and you only want to
    # re-run the image build.
    [switch] $SkipFrontend
)

$ErrorActionPreference = "Stop"

# $ErrorActionPreference does not govern native commands on Windows PowerShell
# 5.1, so every docker/go/git invocation below checks $LASTEXITCODE explicitly.
# This is the exact defect present in deploy/dev/build.ps1, where a failing
# `compose build` still falls through to `up -d`.

$ScriptDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path

function Write-Step { param([string] $Message) Write-Host "[build] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "[ ok ] $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }

function Stop-WithError {
    param([string] $Message)
    Write-Host "[fail] $Message" -ForegroundColor Red
    exit 1
}

function Assert-LastExitCode {
    param([string] $What)
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "$What failed with exit code $LASTEXITCODE"
    }
}

function Assert-CommandAvailable {
    param([string] $Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Stop-WithError "'$Name' was not found on PATH"
    }
}

# --- Preflight ---------------------------------------------------------------

Write-Step "Preflight"

Assert-CommandAvailable docker
Assert-CommandAvailable git

docker info *> $null
Assert-LastExitCode "docker info"
Write-Ok "docker daemon reachable"

# --- Frontend (embedded management panel) ------------------------------------

# The management panel is served from a single HTML file compiled into the Go
# binary via //go:embed (internal/managementasset/embedded/management.html).
# It is a build artifact, not hand-written, and there is no CI step that keeps
# it in sync with the web/management sources. Rebuilding it here, ahead of the
# go build gate below, is what prevents the binary from shipping a stale panel
# after a frontend change. `bun run build` uses vite-plugin-singlefile, so the
# whole app inlines into dist/index.html with no sidecar assets to copy.
$WebDir = Join-Path $RepoRoot "web\management"
$EmbeddedPanel = Join-Path $RepoRoot "internal\managementasset\embedded\management.html"

if ($SkipFrontend) {
    Write-Warn "frontend build skipped (-SkipFrontend); the embedded panel keeps whatever is on disk"
    if (-not (Test-Path $EmbeddedPanel)) {
        Stop-WithError "embedded panel is missing at $EmbeddedPanel and -SkipFrontend was set; the go:embed build would fail"
    }
}
elseif (-not (Test-Path $WebDir)) {
    Write-Warn "web\management not found; leaving the embedded panel untouched"
}
else {
    Assert-CommandAvailable bun

    # Run bun from inside web\management via Push-Location rather than relying on
    # `--cwd`: bun's --cwd only reliably reroutes `run` scripts, not `install`,
    # so cd-ing in is the unambiguous way to target the subproject.
    Push-Location $WebDir
    try {
        Write-Step "bun install (frozen lockfile)"
        & bun install --frozen-lockfile
        Assert-LastExitCode "bun install"
        Write-Ok "frontend dependencies installed"

        Write-Step "bun run build"
        # VERSION is resolved a few lines down from git describe, but vite reads
        # it from the environment (getVersion() in vite.config.ts), so surface
        # the same value here to keep the panel's version banner aligned with
        # the image tag.
        $env:VERSION = (& git -C $RepoRoot describe --tags --always --dirty) | Select-Object -First 1
        Assert-LastExitCode "git describe (frontend version)"
        & bun run build
        Assert-LastExitCode "bun run build"
        Write-Ok "frontend built"
    }
    finally {
        Pop-Location
    }

    $builtPanel = Join-Path $WebDir "dist\index.html"
    if (-not (Test-Path $builtPanel)) {
        Stop-WithError "expected build output not found at $builtPanel"
    }

    Write-Step "sync embedded panel"
    Copy-Item -Path $builtPanel -Destination $EmbeddedPanel -Force
    Write-Ok "updated $EmbeddedPanel"
}

if (-not $SkipChecks) {
    Assert-CommandAvailable go

    # gofmt reports files needing formatting on stdout and exits 0 either way,
    # so the output itself is the signal.
    Write-Step "gofmt"
    $unformatted = & gofmt -l $RepoRoot 2>&1 | Where-Object { $_ -match '\S' }
    Assert-LastExitCode "gofmt"
    if ($unformatted) {
        Write-Warn "These files are not gofmt-clean:"
        $unformatted | ForEach-Object { Write-Host "       $_" }
        Stop-WithError "Run 'gofmt -w .' and try again."
    }
    Write-Ok "gofmt clean"

    Write-Step "go build"
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "cliproxy-build-probe-$PID.exe"
    try {
        & go build -o $probe "$RepoRoot\cmd\server"
        Assert-LastExitCode "go build"
        Write-Ok "compiles"
    } finally {
        if (Test-Path $probe) { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
    }
}
else {
    Write-Warn "gofmt / go build gates skipped (-SkipChecks)"
}

# A BOM in front of the first key makes the YAML parser fail on an otherwise
# valid compose file. These files are read by docker compose on the server, so
# they never pass through a Dockerfile sed that could strip it.
Write-Step "BOM scan"
$bomSuspects = @(
    "$RepoRoot\deploy\dev\docker-compose.yml",
    "$RepoRoot\deploy\dev\docker-compose.cluster.yml",
    "$RepoRoot\config.example.yaml"
) | Where-Object { Test-Path $_ }

$bomFound = @()
foreach ($file in $bomSuspects) {
    $head = [System.IO.File]::ReadAllBytes($file) | Select-Object -First 3
    if ($head.Count -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
        $bomFound += $file
    }
}
if ($bomFound.Count -gt 0) {
    $bomFound | ForEach-Object { Write-Host "       $_" }
    Stop-WithError "The files above start with a UTF-8 BOM. Rewrite them without one."
}
Write-Ok "no BOM in compose/config files"

# --- Version ----------------------------------------------------------------

$VERSION = (& git -C $RepoRoot describe --tags --always --dirty) | Select-Object -First 1
Assert-LastExitCode "git describe"
$COMMIT = (& git -C $RepoRoot rev-parse --short HEAD) | Select-Object -First 1
Assert-LastExitCode "git rev-parse"
$BUILD_DATE = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

if ($VERSION -match '-dirty$') {
    Write-Warn "Working tree is dirty; the tag will carry a -dirty suffix: $VERSION"
}

# --- Image reference ---------------------------------------------------------

$imageBase = $Repository
if ($Namespace) { $imageBase = "$Namespace/$Repository" }
if ($Registry)  { $imageBase = "$Registry/$imageBase" }

# Default behavior: push to registry unless -Local or -Save is specified
$shouldPush = -not $Local -and -not $Save
if ($shouldPush -and -not $Registry) {
  Stop-WithError "Cannot push without -Registry. Use -Local to build without pushing."
}

$imageRef = "${imageBase}:${VERSION}"

Write-Host ""
Write-Host "  image:      $imageRef"
Write-Host "  version:    $VERSION"
Write-Host "  commit:     $COMMIT"
Write-Host "  build date: $BUILD_DATE"
Write-Host "  platform:   $Platform"
Write-Host ""

# --- Build ------------------------------------------------------------------

Write-Step "docker build"

$buildArgs = @(
    "build",
    "--platform", $Platform,
    "--build-arg", "VERSION=$VERSION",
    "--build-arg", "COMMIT=$COMMIT",
    "--build-arg", "BUILD_DATE=$BUILD_DATE",
    "-f", "$RepoRoot\Dockerfile",
    "-t", $imageRef
)
if (-not $NoLatest) { $buildArgs += @("-t", "${imageBase}:latest") }
if ($NoCache)    { $buildArgs += "--no-cache" }
$buildArgs += $RepoRoot

& docker @buildArgs
Assert-LastExitCode "docker build"
Write-Ok "built $imageRef"

# --- Deliver ----------------------------------------------------------------

if ($shouldPush) {
    Write-Step "docker login $Registry"
    # No -u/-p on purpose: credentials belong in the platform credential store,
    # not in a script or a shell history.
    & docker login $Registry
    Assert-LastExitCode "docker login"

    Write-Step "docker push $imageRef"
    & docker push $imageRef
    Assert-LastExitCode "docker push (version tag)"
    Write-Ok "pushed $imageRef"

    if (-not $NoLatest) {
        Write-Step "docker push ${imageBase}:latest"
        & docker push "${imageBase}:latest"
        Assert-LastExitCode "docker push (latest tag)"
        Write-Ok "pushed ${imageBase}:latest"
    }

    Write-Host ""
    if (-not $NoLatest) {
        Write-Host "On the server (deploy.sh defaults to this image and the :latest tag):"
        Write-Host "  docker login $Registry"
        Write-Host "  /root/deploy.sh"
        Write-Host ""
        Write-Host "To pin this exact build instead:"
        Write-Host "  /root/deploy.sh --version $VERSION"
    }
    else {
        Write-Host "On the server (no :latest tag was pushed, so the tag must be pinned):"
        Write-Host "  docker login $Registry"
        Write-Host "  /root/deploy.sh --version $VERSION"
    }
}
elseif ($Save) {
    $outDir = Join-Path $RepoRoot "dist"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

    $safeName = ($Repository -replace '[^A-Za-z0-9._-]', '-')
    $tarPath = Join-Path $outDir "$safeName-$VERSION.tar"
    $gzPath = "$tarPath.gz"

    Write-Step "docker save"
    # -o rather than a pipe: PowerShell pipelines are text-oriented and would
    # corrupt the binary stream.
    & docker save -o $tarPath $imageRef
    Assert-LastExitCode "docker save"

    Write-Step "gzip"
    $inStream = $null; $outStream = $null; $gzStream = $null
    try {
        $inStream = [System.IO.File]::OpenRead($tarPath)
        $outStream = [System.IO.File]::Create($gzPath)
        $gzStream = New-Object System.IO.Compression.GZipStream($outStream, [System.IO.Compression.CompressionMode]::Compress)
        $inStream.CopyTo($gzStream)
    } finally {
        if ($gzStream)  { $gzStream.Dispose() }
        if ($outStream) { $outStream.Dispose() }
        if ($inStream)  { $inStream.Dispose() }
    }
    Remove-Item $tarPath -Force

    $sizeMb = [math]::Round((Get-Item $gzPath).Length / 1MB, 1)
    Write-Ok "wrote $gzPath ($sizeMb MB)"

    Write-Host ""
    Write-Host "Transfer and load:"
    Write-Host "  scp `"$gzPath`" root@<server>:/tmp/"
    Write-Host "  ssh root@<server> 'gunzip -c /tmp/$(Split-Path $gzPath -Leaf) | docker load'"
    Write-Host ""
    Write-Host "Then on the server:"
    Write-Host "  cd /root/cliproxyapi-docker"
    Write-Host "  sed -i 's|^CLI_PROXY_IMAGE=.*|CLI_PROXY_IMAGE=$imageBase|' .env"
    Write-Host "  sed -i 's|^CLI_PROXY_VERSION=.*|CLI_PROXY_VERSION=$VERSION|' .env"
    Write-Host "  docker compose up -d"
}
else {
    Write-Host ""
    Write-Host "Image built locally only (-Local). To push it to a registry, run without -Local."
}
