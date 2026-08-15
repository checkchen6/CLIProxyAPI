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
#   2. Routine upgrades (default): pull the configured image tag and recreate
#      the container. Defaults to :latest; pass --version to pin a tag.
#
# The script is self-contained. On first run it renders docker-compose.yml, .env
# and a starter config.yaml (with freshly generated random keys) into the
# deployment directory, and never overwrites them afterwards, so hand edits
# survive later upgrades. Nothing here needs a checkout of this repository on
# the server: scp this single file over and run it.
#
# Usage:
#   ./deploy.sh                             # deploy or upgrade to :latest (default)
#   ./deploy.sh --version v7.2.119          # pin an explicit tag instead
#   ./deploy.sh --from-binary               # first run: migrate off the systemd unit
#   ./deploy.sh --dry-run                   # print every command without running it
#
# Overridable via environment or flags:
#   CLI_PROXY_DEPLOY_DIR      deployment directory       (default /root/cliproxyapi-docker)
#   CLI_PROXY_LEGACY_DIR      old binary install dir     (default /root/cliproxyapi)
#   CLI_PROXY_LEGACY_AUTH_DIR old credential dir         (default /root/.cli-proxy-api)
#   CLI_PROXY_SERVICE         old systemd unit name      (default cliproxyapi)
#   CLI_PROXY_IMAGE           image repository           (default registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api)
#   CLI_PROXY_VERSION         image tag                  (default latest)
#   CLI_PROXY_BIND            host bind address          (default 127.0.0.1)
#   CLI_PROXY_PORT            host port                  (default 8317)

set -euo pipefail

VERSION="${CLI_PROXY_VERSION:-latest}"
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
    sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'
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

[ -n "$VERSION" ] || die "--version was given an empty value. Omit the flag to use the default 'latest', or pass an explicit tag such as v7.2.118."

case "$VERSION" in
    latest)
        # Floating tag: deliberate default so a plain ./deploy.sh ships the newest
        # build. start_stack() always runs an explicit `docker compose pull`, so
        # each run of this script does pick up a freshly published :latest.
        # pull_policy stays `missing` in the rendered compose file, which means a
        # container restart or host reboot reuses the local image instead of
        # failing when the registry is unreachable.
        log "image tag: latest (floating; pass --version vX.Y.Z to pin a build)"
        ;;
    v*) : ;;
    *) warn "Image tags published by CI carry a leading 'v' (VERSION=\${GITHUB_REF_NAME} in .github/workflows/docker-image.yml). '${VERSION}' may not resolve." ;;
esac

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------

COMPOSE=()

preflight() {
    log "Preflight checks"

    command -v docker >/dev/null 2>&1 || die "没找到 docker 命令，请先安装 Docker Engine。"

    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "'docker compose' 和 'docker-compose' 都不可用，请先安装 compose 插件。"
    fi
    ok "compose command: ${COMPOSE[*]}"

    docker info >/dev/null 2>&1 || die "连不上 Docker daemon。确认它在运行（systemctl status docker），以及当前用户有权限。"
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
#   3. CLI_PROXY_VERSION defaults to `latest`, matching deploy.sh's own default.
#      Pin an explicit tag in .env when a build needs to stay put.
#   4. Relative volume paths resolve against this file's directory, because the
#      compose file lives in the deployment directory. No --project-directory
#      juggling needed.
services:
  cli-proxy-api:
    image: ${CLI_PROXY_IMAGE:-registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api}:${CLI_PROXY_VERSION:-latest}
    # `missing` rather than `always`: a container restart or host reboot reuses
    # the local image instead of failing when the registry is unreachable.
    # Upgrades go through an explicit `docker compose pull`, which deploy.sh
    # always runs -- so a floating :latest is still refreshed on every deploy.
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
            ok ".env already set to ${VERSION}"
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

# Hex string generator for the generated credentials. openssl is the common
# case; /dev/urandom keeps this working on minimal images that ship neither
# openssl nor a package manager.
gen_random_hex() {
    local bytes="${1:-24}"

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes" && return 0
    fi

    if [ -r /dev/urandom ]; then
        # od + tr rather than `head -c ... | base64`: base64 can emit '/' and '+',
        # which would need quoting care inside the YAML this feeds.
        od -An -tx1 -N "$bytes" /dev/urandom | tr -d ' \n' && printf '\n' && return 0
    fi

    return 1
}

# Render a starter config.yaml when the deployment directory has none.
#
# Skipped for --from-binary, where migrate_payload copies the existing file over
# instead -- generating one first would only trigger the "overwrite?" prompt.
#
# Never overwrites an existing file. The secret-key inside is replaced by its
# bcrypt hash on first start, so clobbering it would lock the operator out of
# the management panel with no way to recover the old value.
write_config_file() {
    local target="${DEPLOY_DIR}/config.yaml"

    if [ -f "$target" ]; then
        ok "config.yaml already present, left untouched"
        return 0
    fi

    if [ "$FROM_BINARY" -eq 1 ]; then
        log "config.yaml will be migrated from ${LEGACY_DIR} (--from-binary)"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '       would write: %s (with a generated api-key and secret-key)\n' "$target"
        return 0
    fi

    local api_key secret_key
    api_key="sk-$(gen_random_hex 24)" || die "cannot generate an API key: neither openssl nor /dev/urandom is usable. Create ${target} by hand."
    secret_key="$(gen_random_hex 24)" || die "cannot generate a management key: neither openssl nor /dev/urandom is usable. Create ${target} by hand."

    cat > "$target" <<CONFIG_YAML
# Rendered by deploy.sh on first run. Edit freely -- later runs never overwrite
# this file.
#
# Three values are container-specific. Changing them breaks the deployment:
#
#   host      Must stay "". The process then binds every interface INSIDE the
#             container. A loopback value binds the container's own lo, and the
#             published port maps to nothing -- the service looks completely
#             dead from outside while the logs look fine. Exposure is
#             controlled by CLI_PROXY_BIND in .env, not by this field.
#   port      Must stay 8317, which is the container side of the compose port
#             mapping.
#   auth-dir  Must stay /root/.cli-proxy-api, the volume mount target. Any
#             other path writes OAuth credentials into the container layer,
#             where they are lost on the next recreate.
host: ""
port: 8317
auth-dir: "/root/.cli-proxy-api"

remote-management:
  # Must be true for a container deployment. The handler decides "local client"
  # by comparing the source IP against 127.0.0.1 / ::1 literally, and under
  # Docker the source is never loopback: SNAT rewrites it to the bridge gateway
  # (172.x.0.1), while requests through a reverse proxy carry the real public
  # IP. With false, every management request is rejected with 403.
  #
  # Compensate with the strong secret-key below, HTTPS-only exposure, and an IP
  # allowlist on the management paths in the reverse proxy.
  allow-remote: true

  # Generated by deploy.sh. Replaced by its bcrypt hash on first start.
  secret-key: "${secret_key}"

  disable-control-panel: false

# Client-facing keys. Generated by deploy.sh; add more entries as needed.
api-keys:
  - "${api_key}"

debug: false
logging-to-file: false

# Leave empty for direct connections. Servers in regions that OpenAI/Anthropic
# block (mainland China, Hong Kong) need an egress proxy here, for example
# "socks5://user:pass@host:1080".
proxy-url: ""

request-retry: 3

routing:
  strategy: "round-robin"
CONFIG_YAML

    ok "wrote ${target}"
    printf '\n'
    warn "已生成密钥，请立刻复制保存（secret-key 只显示这一次）："
    printf '         api-key    客户端调用用    : %s\n' "$api_key"
    printf '         secret-key 管理面板登录用  : %s\n' "$secret_key"
    warn "容器首次启动后，config.yaml 里的 secret-key 会被换成 bcrypt 哈希，明文无法再从文件恢复。"
    printf '\n'
}

scaffold() {
    log "Preparing ${DEPLOY_DIR}"
    run mkdir -p "${DEPLOY_DIR}/auths" "${DEPLOY_DIR}/logs" "${DEPLOY_DIR}/plugins"
    write_compose_file
    write_env_file
    write_config_file
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

    warn "即将停止并 disable 旧服务 ${SERVICE_NAME}.service。"
    warn "两套部署都占用 ${HOST_PORT} 端口；只 stop 不 disable 的话，服务器重启后旧服务会重新抢占端口。"
    warn "旧的二进制和 unit 文件都会留在原处，回滚只需执行 'systemctl enable --now ${SERVICE_NAME}'。"

    if ! confirm "现在停止并 disable ${SERVICE_NAME}.service 吗？"; then
        die "已取消。旧服务还占着 ${HOST_PORT} 端口，迁移无法继续。"
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

    if [ ! -f "$cfg" ]; then
        # A real run renders config.yaml in scaffold() before reaching this
        # point, so a missing file here only happens under --dry-run, where
        # nothing was actually written. Skipping keeps the dry run able to
        # preview the remaining steps instead of stopping short.
        if [ "$DRY_RUN" -eq 1 ]; then
            log "config.yaml not written yet (dry run); skipping the audit"
            return 0
        fi
        die "config.yaml 不存在且未能自动生成。请手工创建 ${cfg}，或加 --from-binary 从旧的二进制部署迁移。"
    fi

    # A stray BOM makes the YAML parser choke on the very first key.
    if head -c 3 "$cfg" | od -An -tx1 2>/dev/null | tr -d ' \n' | grep -qi '^efbbbf$'; then
        warn "config.yaml 带 UTF-8 BOM，YAML 会在第一个键上解析失败。清除：sed -i '1s/^\xEF\xBB\xBF//' ${cfg}"
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
            warn "host 写成了 '${host_value}'。容器里这只会绑定容器自己的回环网卡，宿主机的端口映射会打到空处，表现是服务像完全死了。"
            warn "请把 ${cfg} 里改成 host: \"\"。对外暴露范围由端口绑定地址（${BIND_ADDR}）控制，不是靠这个字段。"
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
            warn "auth-dir 没有设置。请加上 auth-dir: \"/root/.cli-proxy-api\"，否则 OAuth 凭据不会落在 ./auths 挂载里。"
            AUDIT_FAILED=1
            ;;
        *)
            warn "auth-dir 是 '${auth_dir}'，不是卷挂载目标 /root/.cli-proxy-api。凭据会被写进容器层，容器重建后全部丢失（需要重新授权所有账号）。"
            AUDIT_FAILED=1
            ;;
    esac

    local port_value
    port_value="$(read_top_level_scalar "$cfg" port)"
    if [ -n "$port_value" ] && [ "$port_value" != "8317" ]; then
        warn "config.yaml 里 port 是 ${port_value}，但 compose 映射的容器端口是 8317。两者必须一致，否则端口映射打不到监听进程。"
        AUDIT_FAILED=1
    fi

    # allow-remote governs the management API. Docker's SNAT rewrites the source
    # address to the bridge gateway, so a direct on-host curl no longer looks
    # like 127.0.0.1 to the handler (internal/api/handlers/management/handler.go
    # compares the string literally).
    # disable-control-panel: true makes GET /management.html return a bare 404
    # with no hint about why, which is genuinely hard to diagnose from the
    # outside -- the image, the reverse proxy and every other check look fine.
    if grep -qE '^[[:space:]]+disable-control-panel:[[:space:]]*true' "$cfg"; then
        warn "disable-control-panel 是 true，管理面板 /management.html 会直接返回 404（镜像和反代都正常也一样打不开）。"
        warn "要用面板就把 ${cfg} 里这一项改成 false，然后执行 'docker compose restart'。"
        AUDIT_FAILED=1
    fi

    if grep -q '^remote-management:' "$cfg"; then
        if grep -qE '^[[:space:]]+allow-remote:[[:space:]]*true' "$cfg"; then
            ok "remote-management.allow-remote is true"
        else
            log "remote-management.allow-remote is false. Requests arriving through the host reverse proxy are unaffected (X-Forwarded-For already makes them non-local), but a direct 'curl 127.0.0.1:${HOST_PORT}/v0/management/...' on this host will now see the Docker bridge gateway as its source address and get 403."
        fi
    fi

    if [ "$AUDIT_FAILED" -eq 1 ]; then
        if ! confirm "配置体检有上面这些警告，仍要继续吗？"; then
            die "已停止。请先修正 ${cfg} 再重跑。"
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
        ok "容器状态：running"
    else
        warn "容器状态异常：${state}"
        warn "查看日志排查：docker logs --tail 80 ${CONTAINER_NAME}"
        return 1
    fi

    # The binary prints its version as the first line of main(), before any flag
    # parsing, so this is the build's own claim rather than a tag guess.
    local reported
    reported="$(docker logs "$CONTAINER_NAME" 2>&1 | grep -m 1 'CLIProxyAPI Version:' || true)"
    if [ -n "$reported" ]; then
        ok "${reported}"
    else
        warn "日志里还没打印版本横幅（容器刚启动，通常等几秒即可，不影响部署）。手动确认：docker logs ${CONTAINER_NAME} | grep Version"
    fi

    # The acceptance check for the firewall-bypass problem: this must show the
    # loopback address, not 0.0.0.0.
    if command -v ss >/dev/null 2>&1; then
        local listen
        listen="$(ss -tlnH "sport = :${HOST_PORT}" 2>/dev/null | awk '{print $4}' | paste -sd' ' -)"
        if [ -n "$listen" ]; then
            case "$listen" in
                *"0.0.0.0:${HOST_PORT}"* | *":::${HOST_PORT}"* | *"*:${HOST_PORT}"*)
                    warn "危险：端口 ${HOST_PORT} 绑定在 ${listen}（所有网卡），等于直接暴露到公网。"
                    warn "Docker 的 DNAT 规则在 DOCKER 链，早于 INPUT，宝塔/ufw/firewalld 的放行规则管不住它。"
                    warn "请把 ${DEPLOY_DIR}/.env 里的 CLI_PROXY_BIND 改成 127.0.0.1，再执行 'docker compose up -d'。"
                    ;;
                *)
                    ok "端口 ${HOST_PORT} 绑定在 ${listen}（仅本机，正确）"
                    ;;
            esac
        else
            warn "端口 ${HOST_PORT} 上没有监听，服务可能没起来"
        fi
    else
        log "ss 命令不可用，跳过绑定地址检查"
    fi

    local key
    key="$(first_api_key "${DEPLOY_DIR}/config.yaml" || true)"
    if command -v curl >/dev/null 2>&1 && [ -n "$key" ]; then
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
            -H "Authorization: Bearer ${key}" \
            "http://127.0.0.1:${HOST_PORT}/v1/models" || echo "000")"
        if [ "$code" = "200" ]; then
            ok "接口自测通过：GET /v1/models 返回 200（服务真的可用了）"
        else
            warn "接口自测失败：GET /v1/models 返回 ${code}（期望 200）。查日志：docker logs ${CONTAINER_NAME}"
        fi
    else
        log "跳过接口自测（没有 curl，或 config.yaml 里没有 api-keys）"
    fi
}

summary() {
    cat <<SUMMARY

$(printf '%s' "$C_OK")部署完成。$(printf '%s' "$C_OFF")当前镜像 tag：${VERSION}

日常命令（都在 ${DEPLOY_DIR} 目录下执行）：

  cd ${DEPLOY_DIR}
  docker compose logs -f --tail 100     # 看日志（默认输出到 stdout）
  docker compose restart                # 配置改动没被自动加载时重启
  docker compose down                   # 停止

升级：直接重跑本脚本（默认 :latest，每次都会先 pull）；
      或改 .env 里的 CLI_PROXY_VERSION，再执行 'docker compose pull && docker compose up -d'。

回滚到指定版本：./deploy.sh --version vX.Y.Z
查看当前实际运行的版本：docker logs ${CONTAINER_NAME} 2>&1 | grep -m1 'CLIProxyAPI Version:'

接下来通常还要做：
  1. 用反向代理（宝塔 / Nginx）把域名指到 127.0.0.1:${HOST_PORT}，并配好 HTTPS
  2. 打开管理面板 https://你的域名/management.html ，用上面的 secret-key 登录
  3. 在面板里添加 Gemini / Claude / Codex 等提供商账号

回滚到旧的二进制部署（相关文件都还在原处）：

  cd ${DEPLOY_DIR} && docker compose down
  systemctl enable --now ${SERVICE_NAME}
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
