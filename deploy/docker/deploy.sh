#!/usr/bin/env bash
#
# deploy.sh - Server-side deployment driver for the Docker-based single-node setup.
#
# Two jobs:
#
#   1. One-shot migration off a systemd binary deployment (--from-binary):
#      stop and disable the old unit, back it up, then copy config.yaml and the
#      OAuth credential directory into the Docker deployment directory.
#
#   2. Routine upgrades (default): pull the pinned image tag and recreate the
#      container.
#
# The script is self-contained. It renders docker-compose.yml and .env into the
# deployment directory on first run and never overwrites them afterwards, so
# hand edits survive later upgrades. Nothing here needs a checkout of this
# repository on the server: scp this single file over and run it.
#
# Usage:
#   ./deploy.sh --version v7.2.118 --from-binary
#   ./deploy.sh --version v7.2.119
#   ./deploy.sh --version v7.2.119 --dry-run
#
# Overridable via environment or flags:
#   CLI_PROXY_DEPLOY_DIR      deployment directory       (default /root/cliproxyapi-docker)
#   CLI_PROXY_LEGACY_DIR      old binary install dir     (default /root/cliproxyapi)
#   CLI_PROXY_LEGACY_AUTH_DIR old credential dir         (default /root/.cli-proxy-api)
#   CLI_PROXY_SERVICE         old systemd unit name      (default cliproxyapi)
#   CLI_PROXY_IMAGE           image repository           (default registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api)
#   CLI_PROXY_BIND            host bind address          (default 127.0.0.1)
#   CLI_PROXY_PORT            host port                  (default 8317)

set -euo pipefail

VERSION=""
DEPLOY_DIR="${CLI_PROXY_DEPLOY_DIR:-/root/cliproxyapi-docker}"
LEGACY_DIR="${CLI_PROXY_LEGACY_DIR:-/root/cliproxyapi}"
LEGACY_AUTH_DIR="${CLI_PROXY_LEGACY_AUTH_DIR:-/root/.cli-proxy-api}"
SERVICE_NAME="${CLI_PROXY_SERVICE:-cliproxyapi}"
IMAGE="${CLI_PROXY_IMAGE:-registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api}"
BIND_ADDR="${CLI_PROXY_BIND:-127.0.0.1}"
HOST_PORT="${CLI_PROXY_PORT:-8317}"
CONTAINER_NAME="cli-proxy-api"

FROM_BINARY=0
ASSUME_YES=0
DRY_RUN=0
STAMP="$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------

if [ -t 1 ]; then
    C_INFO=$'\033[0;36m'; C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'
    C_ERR=$'\033[0;31m';  C_OFF=$'\033[0m'
else
    C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

log()  { printf '%s[deploy]%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n'   "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n'   "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

# Execute a command, or print it when running with --dry-run. Arguments are
# passed through as an array, never re-parsed by a shell, so paths with spaces
# stay intact.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '       would run: %s\n' "$*"
        return 0
    fi
    "$@"
}

confirm() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    local reply=""
    printf '%s[ask ]%s %s [y/N] ' "$C_WARN" "$C_OFF" "$1"
    # Guard the read: under `set -e` an EOF (non-interactive stdin) would
    # otherwise abort the whole script instead of declining the prompt.
    read -r reply || true
    case "$reply" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --version)         VERSION="${2:?--version needs a value, e.g. v7.2.118}"; shift 2 ;;
        --version=*)       VERSION="${1#*=}"; shift ;;
        --deploy-dir)      DEPLOY_DIR="${2:?--deploy-dir needs a value}"; shift 2 ;;
        --deploy-dir=*)    DEPLOY_DIR="${1#*=}"; shift ;;
        --legacy-dir)      LEGACY_DIR="${2:?--legacy-dir needs a value}"; shift 2 ;;
        --legacy-dir=*)    LEGACY_DIR="${1#*=}"; shift ;;
        --legacy-auth-dir) LEGACY_AUTH_DIR="${2:?--legacy-auth-dir needs a value}"; shift 2 ;;
        --service)         SERVICE_NAME="${2:?--service needs a value}"; shift 2 ;;
        --bind)            BIND_ADDR="${2:?--bind needs a value}"; shift 2 ;;
        --port)            HOST_PORT="${2:?--port needs a value}"; shift 2 ;;
        --from-binary)     FROM_BINARY=1; shift ;;
        --yes | -y)        ASSUME_YES=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --help | -h)       usage 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1" >&2; usage 1 ;;
    esac
done

[ -n "$VERSION" ] || die "--version is required (e.g. --version v7.2.118). Pinning the tag keeps upgrades deliberate; 'latest' is intentionally not accepted."

case "$VERSION" in
    latest) die "'latest' is rejected on purpose: every 'up -d' would silently jump to whatever was published last. Pin an explicit tag such as v7.2.118." ;;
    v*) : ;;
    *) warn "Image tags published by CI carry a leading 'v' (VERSION=\${GITHUB_REF_NAME} in .github/workflows/docker-image.yml). '${VERSION}' may not resolve." ;;
esac

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------

COMPOSE=()

preflight() {
    log "Preflight checks"

    command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine first."

    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "Neither 'docker compose' nor 'docker-compose' is available."
    fi
    ok "compose command: ${COMPOSE[*]}"

    docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Is it running, and do you have permission?"
    ok "docker daemon reachable"

    log "host architecture: $(uname -m) (official manifests cover linux/amd64 and linux/arm64)"
}

# ------------------------------------------------------------------------------
# Deployment directory scaffolding
# ------------------------------------------------------------------------------

# Render docker-compose.yml only when absent. Regenerating it on every run would
# silently revert hand edits made on the server.
write_compose_file() {
    local target="${DEPLOY_DIR}/docker-compose.yml"

    if [ -f "$target" ]; then
        ok "docker-compose.yml already present, left untouched"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '       would write: %s\n' "$target"
        return 0
    fi

    # Quoted heredoc: ${...} must reach Compose verbatim, not be expanded here.
    cat <<'COMPOSE_YAML' > "$target"
# Single-node production compose file, rendered by deploy.sh.
#
# Differences from deploy/dev/docker-compose.yml in the repository:
#
#   1. No `build:` section. This file only consumes published images; the server
#      never compiles Go or downloads a module cache.
#   2. The published port binds to a host address supplied through
#      CLI_PROXY_BIND, default 127.0.0.1. Docker installs its DNAT rules in the
#      DOCKER chain, which is traversed before INPUT, so a 0.0.0.0 binding is
#      NOT covered by ufw/firewalld/BT-panel rules. Keep it on loopback and let
#      the host reverse proxy terminate TLS.
#   3. CLI_PROXY_VERSION is required rather than defaulted, so a missing value
#      fails loudly instead of resolving to `latest`.
#   4. Relative volume paths resolve against this file's directory, because the
#      compose file lives in the deployment directory. No --project-directory
#      juggling needed.
services:
  cli-proxy-api:
    image: ${CLI_PROXY_IMAGE:-registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api}:${CLI_PROXY_VERSION:?CLI_PROXY_VERSION is required, e.g. v7.2.118}
    # The tag is pinned, so re-checking the registry on every start buys
    # nothing. Upgrades go through `docker compose pull` explicitly.
    pull_policy: missing
    container_name: cli-proxy-api
    environment:
      # The image already bakes in Asia/Shanghai; kept here so it can be
      # overridden from .env without rebuilding.
      TZ: ${TZ:-Asia/Shanghai}
    ports:
      - "${CLI_PROXY_BIND:-127.0.0.1}:${CLI_PROXY_PORT:-8317}:8317"
      # OAuth callback listeners. Credentials carried over from an existing
      # deployment keep working, so these stay closed by default. To add a new
      # provider account later, uncomment the one you need and reach it from
      # your workstation over an SSH tunnel, for example:
      #   ssh -L 54545:127.0.0.1:54545 root@<server>
      # Each provider owns its port and they are not interchangeable.
      # - "${CLI_PROXY_BIND:-127.0.0.1}:54545:54545"  # Anthropic / Claude
      # - "${CLI_PROXY_BIND:-127.0.0.1}:1455:1455"    # Codex
      # - "${CLI_PROXY_BIND:-127.0.0.1}:51121:51121"  # Antigravity
    volumes:
      # config.yaml must already exist as a FILE. Docker creates a directory of
      # the same name when the path is missing, which turns into a crash loop.
      - ./config.yaml:/CLIProxyAPI/config.yaml
      # Must line up with `auth-dir` in config.yaml.
      - ./auths:/root/.cli-proxy-api
      # Empty unless `logging-to-file: true`; logs go to stdout by default.
      - ./logs:/CLIProxyAPI/logs
      - ./plugins:/CLIProxyAPI/plugins
    restart: unless-stopped
COMPOSE_YAML

    ok "wrote ${target}"
}

# Compose auto-loads .env from the project directory, which lets plain
# `docker compose up -d` work later without exporting anything.
write_env_file() {
    local target="${DEPLOY_DIR}/.env"

    if [ -f "$target" ]; then
        local current
        current="$(sed -n 's/^CLI_PROXY_VERSION=//p' "$target" | head -n 1)"
        if [ "$current" = "$VERSION" ]; then
            ok ".env already pins ${VERSION}"
            return 0
        fi
        log "bumping CLI_PROXY_VERSION: ${current:-<unset>} -> ${VERSION}"
        run cp -a "$target" "${target}.bak.${STAMP}"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '       would write: %s (CLI_PROXY_VERSION=%s)\n' "$target" "$VERSION"
        return 0
    fi

    cat > "$target" <<ENV_FILE
# Consumed by docker-compose.yml in this directory. Edit and re-run
# \`docker compose up -d\` to apply.
CLI_PROXY_IMAGE=${IMAGE}
CLI_PROXY_VERSION=${VERSION}
CLI_PROXY_BIND=${BIND_ADDR}
CLI_PROXY_PORT=${HOST_PORT}
TZ=Asia/Shanghai
ENV_FILE

    ok "wrote ${target}"
}

scaffold() {
    log "Preparing ${DEPLOY_DIR}"
    run mkdir -p "${DEPLOY_DIR}/auths" "${DEPLOY_DIR}/logs" "${DEPLOY_DIR}/plugins"
    write_compose_file
    write_env_file
}

# ------------------------------------------------------------------------------
# Migration from the systemd binary deployment
# ------------------------------------------------------------------------------

unit_exists() {
    systemctl list-unit-files --no-legend "${SERVICE_NAME}.service" 2>/dev/null | grep -q "${SERVICE_NAME}.service"
}

stop_legacy_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl not available, nothing to stop"
        return 0
    fi

    if ! unit_exists; then
        log "no ${SERVICE_NAME}.service unit found, nothing to stop"
        return 0
    fi

    warn "About to stop and disable ${SERVICE_NAME}.service."
    warn "Both deployments listen on ${HOST_PORT}; leaving the unit enabled means it grabs the port again after a reboot."
    warn "The old binary and unit file stay on disk, so rolling back is 'systemctl enable --now ${SERVICE_NAME}'."

    if ! confirm "Stop and disable ${SERVICE_NAME}.service now?"; then
        die "Declined. The migration cannot continue while the old service owns port ${HOST_PORT}."
    fi

    run systemctl stop "${SERVICE_NAME}"
    # Disabling matters as much as stopping: Restart=always only covers crashes,
    # but an enabled unit comes back on the next boot and re-takes the port.
    run systemctl disable "${SERVICE_NAME}" || warn "disable returned non-zero; check 'systemctl is-enabled ${SERVICE_NAME}' by hand"
    ok "legacy service stopped and disabled"
}

migrate_payload() {
    local legacy_config="${LEGACY_DIR}/config.yaml"

    [ -f "$legacy_config" ] || die "Legacy config not found at ${legacy_config}. Pass --legacy-dir if it lives elsewhere."

    if [ -f "${DEPLOY_DIR}/config.yaml" ]; then
        warn "${DEPLOY_DIR}/config.yaml already exists."
        if ! confirm "Overwrite it with ${legacy_config}? (a timestamped backup is kept)"; then
            log "keeping the existing config.yaml"
        else
            run cp -a "${DEPLOY_DIR}/config.yaml" "${DEPLOY_DIR}/config.yaml.bak.${STAMP}"
            run cp -a "$legacy_config" "${DEPLOY_DIR}/config.yaml"
            ok "config.yaml replaced (previous copy kept as config.yaml.bak.${STAMP})"
        fi
    else
        run cp -a "$legacy_config" "${DEPLOY_DIR}/config.yaml"
        ok "copied config.yaml"
    fi

    # Back up the source of truth before anything else touches it.
    run cp -a "$legacy_config" "${legacy_config}.bak.${STAMP}"

    if [ ! -d "$LEGACY_AUTH_DIR" ]; then
        warn "Credential directory ${LEGACY_AUTH_DIR} does not exist; skipping credential migration."
        warn "You will have to sign in to each provider again through the management panel."
        return 0
    fi

    run cp -a "$LEGACY_AUTH_DIR" "${LEGACY_AUTH_DIR}.bak.${STAMP}"
    ok "credentials backed up to ${LEGACY_AUTH_DIR}.bak.${STAMP}"

    if [ -n "$(ls -A "${DEPLOY_DIR}/auths" 2>/dev/null || true)" ]; then
        warn "${DEPLOY_DIR}/auths is not empty."
        if ! confirm "Copy credentials over it anyway? (same-named files are replaced)"; then
            log "leaving ${DEPLOY_DIR}/auths as is"
            return 0
        fi
    fi

    # Trailing "/." copies directory *contents*, dotfiles included, without
    # nesting the source directory inside the target.
    run cp -a "${LEGACY_AUTH_DIR}/." "${DEPLOY_DIR}/auths/"
    ok "credentials copied into ${DEPLOY_DIR}/auths"
}

# ------------------------------------------------------------------------------
# Config audit
# ------------------------------------------------------------------------------

# Read a top-level scalar. The pattern is anchored at column 0, so nested keys
# that share a name (codex.host and friends) are ignored.
read_top_level_scalar() {
    local file="$1" key="$2" value
    value="$(sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -n 1)"
    value="${value%%#*}"
    printf '%s' "$value" | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

first_api_key() {
    awk '
        /^api-keys:/ { inblock = 1; next }
        inblock && /^[ \t]*-[ \t]*/ { sub(/^[ \t]*-[ \t]*/, ""); print; exit }
        inblock && /^[^ \t#]/ { exit }
    ' "$1" | tr -d "\"'\r" | sed 's/[[:space:]]*$//'
}

AUDIT_FAILED=0

audit_config() {
    local cfg="${DEPLOY_DIR}/config.yaml"
    log "Auditing ${cfg}"

    [ -f "$cfg" ] || die "config.yaml is missing. Run with --from-binary to migrate it, or drop it in by hand (cp config.example.yaml config.yaml)."

    # A stray BOM makes the YAML parser choke on the very first key.
    if head -c 3 "$cfg" | od -An -tx1 2>/dev/null | tr -d ' \n' | grep -qi '^efbbbf$'; then
        warn "config.yaml starts with a UTF-8 BOM. Strip it: sed -i '1s/^\xEF\xBB\xBF//' ${cfg}"
        AUDIT_FAILED=1
    fi

    # The single most common migration failure. Inside a container a loopback
    # bind means the process only listens on the *container's* lo interface, so
    # the published port maps to nothing and the service looks entirely dead
    # from outside.
    local host_value
    host_value="$(read_top_level_scalar "$cfg" host)"
    case "$host_value" in
        "" | "0.0.0.0" | "::")
            ok "host is '${host_value}' (binds all interfaces inside the container, correct)"
            ;;
        *)
            warn "host is '${host_value}'. Inside a container this binds the container's own loopback only, and the published port will map to nothing."
            warn "Set 'host: \"\"' in ${cfg}. Exposure is already restricted by the ${BIND_ADDR} port binding, not by this setting."
            AUDIT_FAILED=1
            ;;
    esac

    # auth-dir must land on the volume mount target, otherwise credentials are
    # written inside the container layer and vanish on the next recreate.
    local auth_dir
    auth_dir="$(read_top_level_scalar "$cfg" auth-dir)"
    case "$auth_dir" in
        "/root/.cli-proxy-api")
            ok "auth-dir is an explicit ${auth_dir}"
            ;;
        "~/.cli-proxy-api" | "\$HOME/.cli-proxy-api")
            log "auth-dir is '${auth_dir}'; Docker injects HOME=/root so it resolves onto the mount. Consider the explicit '/root/.cli-proxy-api' to drop the implicit HOME dependency."
            ;;
        "")
            warn "auth-dir is not set. Add 'auth-dir: \"/root/.cli-proxy-api\"' so credentials land on the ./auths mount."
            AUDIT_FAILED=1
            ;;
        *)
            warn "auth-dir is '${auth_dir}', which is not the volume target /root/.cli-proxy-api. Credentials would be written into the container layer and lost on recreate."
            AUDIT_FAILED=1
            ;;
    esac

    local port_value
    port_value="$(read_top_level_scalar "$cfg" port)"
    if [ -n "$port_value" ] && [ "$port_value" != "8317" ]; then
        warn "config port is ${port_value} but the compose file maps the container side to 8317. Align them or the mapping misses the listener."
        AUDIT_FAILED=1
    fi

    # allow-remote governs the management API. Docker's SNAT rewrites the source
    # address to the bridge gateway, so a direct on-host curl no longer looks
    # like 127.0.0.1 to the handler (internal/api/handlers/management/handler.go
    # compares the string literally).
    if grep -q '^remote-management:' "$cfg"; then
        if grep -qE '^[[:space:]]+allow-remote:[[:space:]]*true' "$cfg"; then
            ok "remote-management.allow-remote is true"
        else
            log "remote-management.allow-remote is false. Requests arriving through the host reverse proxy are unaffected (X-Forwarded-For already makes them non-local), but a direct 'curl 127.0.0.1:${HOST_PORT}/v0/management/...' on this host will now see the Docker bridge gateway as its source address and get 403."
        fi
    fi

    if [ "$AUDIT_FAILED" -eq 1 ]; then
        if ! confirm "The audit raised warnings above. Continue anyway?"; then
            die "Stopped. Fix ${cfg} and re-run."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Start and verify
# ------------------------------------------------------------------------------

start_stack() {
    log "Pulling ${IMAGE}:${VERSION}"
    run "${COMPOSE[@]}" --project-directory "$DEPLOY_DIR" -f "${DEPLOY_DIR}/docker-compose.yml" pull

    log "Starting the container"
    run "${COMPOSE[@]}" --project-directory "$DEPLOY_DIR" -f "${DEPLOY_DIR}/docker-compose.yml" up -d --remove-orphans
}

verify() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "skipping verification in dry-run mode"
        return 0
    fi

    log "Verifying"
    sleep 3

    local state
    state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")"
    if [ "$state" = "running" ]; then
        ok "container state: running"
    else
        warn "container state: ${state}"
        warn "inspect the logs: docker logs --tail 80 ${CONTAINER_NAME}"
        return 1
    fi

    # The binary prints its version as the first line of main(), before any flag
    # parsing, so this is the build's own claim rather than a tag guess.
    local reported
    reported="$(docker logs "$CONTAINER_NAME" 2>&1 | grep -m 1 'CLIProxyAPI Version:' || true)"
    if [ -n "$reported" ]; then
        ok "${reported}"
    else
        warn "no version banner in the logs yet; check 'docker logs ${CONTAINER_NAME}'"
    fi

    # The acceptance check for the firewall-bypass problem: this must show the
    # loopback address, not 0.0.0.0.
    if command -v ss >/dev/null 2>&1; then
        local listen
        listen="$(ss -tlnH "sport = :${HOST_PORT}" 2>/dev/null | awk '{print $4}' | paste -sd' ' -)"
        if [ -n "$listen" ]; then
            case "$listen" in
                *"0.0.0.0:${HOST_PORT}"* | *":::${HOST_PORT}"* | *"*:${HOST_PORT}"*)
                    warn "port ${HOST_PORT} is published on ${listen} (all interfaces)."
                    warn "Docker's DNAT rules sit in the DOCKER chain, ahead of INPUT, so host firewall rules do NOT cover this. Set CLI_PROXY_BIND=127.0.0.1 in ${DEPLOY_DIR}/.env and re-run 'docker compose up -d'."
                    ;;
                *)
                    ok "port ${HOST_PORT} published on ${listen}"
                    ;;
            esac
        else
            warn "nothing is listening on ${HOST_PORT}"
        fi
    else
        log "ss not available, skipping the bind-address check"
    fi

    local key
    key="$(first_api_key "${DEPLOY_DIR}/config.yaml" || true)"
    if command -v curl >/dev/null 2>&1 && [ -n "$key" ]; then
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
            -H "Authorization: Bearer ${key}" \
            "http://127.0.0.1:${HOST_PORT}/v1/models" || echo "000")"
        if [ "$code" = "200" ]; then
            ok "GET /v1/models returned 200"
        else
            warn "GET /v1/models returned ${code} (expected 200)"
        fi
    else
        log "skipping the /v1/models probe (curl missing, or no api-keys entry in config.yaml)"
    fi
}

summary() {
    cat <<SUMMARY

$(printf '%s' "$C_OK")Done.$(printf '%s' "$C_OFF") Day-to-day commands, all from ${DEPLOY_DIR}:

  cd ${DEPLOY_DIR}
  docker compose logs -f --tail 100     # follow logs (stdout unless logging-to-file is on)
  docker compose restart                # apply a config.yaml change the file watcher missed
  docker compose down                   # stop

Upgrading: edit CLI_PROXY_VERSION in .env, then 'docker compose pull && docker compose up -d',
or re-run this script with a new --version.

Rolling back to the binary deployment (its files were left in place):

  cd ${DEPLOY_DIR} && docker compose down
  systemctl enable --now ${SERVICE_NAME}

The host reverse proxy needs no change: it keeps pointing at 127.0.0.1:${HOST_PORT}.
SUMMARY
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    [ "$DRY_RUN" -eq 1 ] && log "DRY RUN: no changes will be made"

    preflight
    scaffold

    if [ "$FROM_BINARY" -eq 1 ]; then
        stop_legacy_service
        migrate_payload
    fi

    audit_config
    start_stack
    verify
    summary
}

main
