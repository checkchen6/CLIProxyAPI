# Deployment Flow

ASCII diagrams for the single-node Docker deployment driven by
[`deploy.sh`](deploy.sh). Chinese walkthrough: [README_CN.md](README_CN.md).

The default path uses the published multi-arch image and requires **no build
step and no checkout of this repository on the server**. Building your own image
is only necessary when you carry local changes.

---

## 1. Choosing a path

```
                        Do you have local code changes?
                                    |
                 +------------------+------------------+
                 | no                                 | yes
                 v                                    v
      Use the published image                 build-push.ps1
      eceasy/cli-proxy-api:<tag>                      |
      (amd64 + arm64 manifest,               +--------+--------+
       one per v* tag)                       |                 |
                 |                        -Push             -Save
                 |                           |                 |
                 |                    private registry   dist/*.tar.gz
                 |                           |                 |
                 |                      server pulls     scp + docker load
                 |                           |                 |
                 +---------------+-----------+-----------------+
                                 v
                             deploy.sh
```

Nothing about `deploy.sh` assumes the official image; point `CLI_PROXY_IMAGE`
in `.env` at your own repository and it behaves identically.

---

## 2. Building your own image (optional)

```
  Windows workstation
  -------------------
  .\deploy\docker\build-push.ps1 -Save
        |
        |  [gate 1] gofmt -l          -> any output blocks
        |  [gate 2] go build ./cmd/server -> non-zero blocks
        |  [gate 3] BOM scan of compose/config yaml -> BOM blocks
        |
        |  version <- git describe --tags --always --dirty
        |  commit  <- git rev-parse --short HEAD
        v
  docker build --platform linux/amd64
    --build-arg VERSION/COMMIT/BUILD_DATE
    -f Dockerfile  <context: repository root>
        |
        |  Dockerfile stage 1: golang:1.26-bookworm, CGO_ENABLED=1
        |  Dockerfile stage 2: debian:bookworm + tzdata + ca-certificates
        v
  cli-proxy-api:<version>
        |
        +-- -Push -> docker login <registry>   (no -u/-p; credential store only)
        |            docker push <ref>          (exit code checked per push)
        |
        +-- -Save -> docker save -o dist/<name>.tar
                     GZipStream -> dist/<name>.tar.gz
                     (docker save is written with -o, never piped: PowerShell
                      pipelines are text-oriented and corrupt binary streams)
```

Every native command is followed by an explicit `$LASTEXITCODE` check.
`$ErrorActionPreference = "Stop"` does not cover native commands on Windows
PowerShell 5.1, so relying on it alone would let a failed `compose build` fall
through into `up -d`. `deploy/dev/build.ps1` guards against this the same way,
inside its `Invoke-Compose` wrapper.

---

## 3. First deployment: migrating off the systemd binary

```
  scp deploy/docker/deploy.sh root@<server>:/root/
  ssh root@<server>
  chmod +x /root/deploy.sh
  /root/deploy.sh --version v7.2.118 --from-binary
        |
        v
  [preflight]
     docker present, daemon reachable
     compose flavour detected (docker compose | docker-compose)
     uname -m reported
        |
        v
  [scaffold]  /root/cliproxyapi-docker/
     mkdir auths/ logs/ plugins/
     render docker-compose.yml   (skipped if it already exists)
     render .env                 (CLI_PROXY_VERSION bumped, old copy backed up)
        |
        v
  [stop legacy]                        <-- prompts for confirmation
     systemctl stop cliproxyapi
     systemctl disable cliproxyapi
        |     stop alone is not enough: Restart=always only covers crashes,
        |     but an enabled unit returns on the next boot and re-takes 8317
        v
  [migrate payload]
     cp /root/cliproxyapi/config.yaml       -> ./config.yaml
     cp /root/cliproxyapi/config.yaml       -> *.bak.<stamp>
     cp -a /root/.cli-proxy-api             -> *.bak.<stamp>
     cp -a /root/.cli-proxy-api/.           -> ./auths/
        |
        v
  [audit config.yaml]                  <-- warnings prompt to continue
     BOM at offset 0?                        -> blocks YAML parsing
     host: must be "" / 0.0.0.0 / ::         -> a loopback value binds the
                                                CONTAINER's lo, and the
                                                published port maps to nothing
     auth-dir: must reach /root/.cli-proxy-api -> otherwise credentials are
                                                  written into the container
                                                  layer and lost on recreate
     port: must be 8317                      -> compose maps the container side
     allow-remote: false                     -> informational; Docker SNAT makes
                                                on-host curl non-local
        |
        v
  [start]
     docker compose pull
     docker compose up -d --remove-orphans
        |
        v
  [verify]
     docker inspect  -> State.Status == running
     docker logs     -> "CLIProxyAPI Version: ..." banner
                        (printed by main() before flag parsing, so it is the
                         build's own claim rather than a tag guess)
     ss -tlnH        -> must be 127.0.0.1:8317, NOT 0.0.0.0:8317
     curl /v1/models -> expect 200, using the first api-keys entry
```

The `ss` line is the acceptance check that matters most. Docker installs its
DNAT rules in the `DOCKER` chain, which iptables traverses **before** `INPUT`,
so a `0.0.0.0` publication is not covered by ufw, firewalld, or a control-panel
firewall. The API key would be the only thing standing in front of it.

Rollback stays cheap because the old binary, its version directories, and the
unit file are all left in place:

```
  cd /root/cliproxyapi-docker && docker compose down
  systemctl enable --now cliproxyapi
```

---

## 4. Routine upgrades

```
  Option A - re-run the script
  ---------------------------
  /root/deploy.sh --version v7.2.119
        |
        |  compose file: left alone (already exists)
        |  .env: CLI_PROXY_VERSION bumped, previous copy kept as .env.bak.<stamp>
        |  legacy migration: skipped (no --from-binary)
        v
  pull -> up -d -> verify


  Option B - by hand
  ------------------
  cd /root/cliproxyapi-docker
  vi .env                      # CLI_PROXY_VERSION=v7.2.119
  docker compose pull
  docker compose up -d
  docker compose logs -f --tail 50
```

Both paths are non-destructive: `config.yaml`, `auths/`, `logs/`, and
`plugins/` all live on bind mounts outside the container.

Config edits are picked up by the file watcher without a restart. Restart only
when the watcher itself failed to start.

---

## 5. Request routing

```
  Client (browser, IDE, SDK)
        |
        |  HTTPS, public DNS
        v
  Host reverse proxy (control panel Nginx, Caddy, ...)
    - terminates TLS
    - sets X-Forwarded-For
        |
        |  proxy_pass http://127.0.0.1:8317
        v
  Docker published port  127.0.0.1:8317 -> container 8317
    - DNAT in the DOCKER chain
    - SNAT rewrites the source address to the bridge gateway (172.x.0.1)
        |
        v
  CLIProxyAPI in the container, listening on 0.0.0.0:8317
    - host: "" in config.yaml is what makes this binding possible
        |
        +-- /v1/*, /v1beta/*  -> provider APIs, guarded by api-keys
        +-- /v0/management/*  -> management API, guarded by secret-key
        |        and by allow-remote when the caller is not 127.0.0.1/::1
        |
        |   c.ClientIP() honours X-Forwarded-For, because no SetTrustedProxies
        |   call narrows Gin's default of trusting every proxy. Requests coming
        |   through the reverse proxy therefore carry the real client address
        |   and are never treated as local.
        v
  Upstream providers (Gemini / Claude / Codex / ...)
```

OAuth callback ports (`54545` Claude, `1455` Codex, `51121` Antigravity) are
commented out in the generated compose file. Credentials carried over from an
earlier deployment keep working, so they are only needed when adding a new
provider account. When that happens, uncomment the single port you need and
reach it through an SSH tunnel rather than publishing it:

```
  ssh -L 54545:127.0.0.1:54545 root@<server>
```

The callback lands on `http://localhost:<port>/...` in **your** browser, so the
port has to be reachable from your workstation, not from the internet. The
three ports are provider-specific and not interchangeable; a missing one fails
by timing out after roughly five minutes instead of erroring immediately.

---

## 6. Data persistence

```
  /root/cliproxyapi-docker/            (host)                container
  |
  +-- docker-compose.yml     rendered once, then yours to edit
  +-- .env                   CLI_PROXY_IMAGE / VERSION / BIND / PORT
  |
  +-- config.yaml       <-->  /CLIProxyAPI/config.yaml
  |     must exist as a FILE before the first start. Docker creates a
  |     directory of the same name when the path is missing, which turns into
  |     a crash loop that needs `rm -rf config.yaml` to clear.
  |
  +-- auths/            <-->  /root/.cli-proxy-api
  |     OAuth credentials. Must match `auth-dir`. The file watcher picks up
  |     new credential files without a restart.
  |
  +-- logs/             <-->  /CLIProxyAPI/logs
  |     Empty unless `logging-to-file: true`; stdout is the default, read it
  |     with `docker compose logs -f`. Note that ResolveLogDirectory prefers
  |     $WRITABLE_PATH/logs when that variable is set, which would bypass this
  |     mount.
  |
  +-- plugins/          <-->  /CLIProxyAPI/plugins
        Optional shared-library plugins.

  Backups kept by deploy.sh (never pruned automatically):
    ./config.yaml.bak.<stamp>              existing config replaced on migration
    ./.env.bak.<stamp>                     version bumped
    /root/cliproxyapi/config.yaml.bak.<stamp>
    /root/.cli-proxy-api.bak.<stamp>
```

No database and no cache service. Local file storage is the default and needs
no environment variables at all; Postgres, git, and object-store backends are
opt-in through the `PGSTORE_*`, `GITSTORE_*`, and `OBJECTSTORE_*` variables
documented in [`.env.example`](../../.env.example).
