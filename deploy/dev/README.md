# Docker Deployment

Docker deployment guide for CLIProxyAPI. The image contains a single Go binary: no web server, no process manager, no database to initialize.

Chinese version: [README_CN.md](README_CN.md). For host-level topics (egress proxies for restricted regions, reverse proxy with HTTPS, firewall rules, client setup) see [DEPLOYMENT_CN.md](../../DEPLOYMENT_CN.md) in the repository root — that document is Chinese only, there is no English equivalent yet.

## 1. Layout

```
<repository root>/
├── Dockerfile              # Stays at the root: the release workflow builds with context "."
├── .dockerignore           # Must stay at the root: Docker only reads it from the build context root
└── deploy/dev/
    ├── docker-compose.yml          # Single-node deployment
    ├── docker-compose.cluster.yml  # Cluster mode, driven by a Home JWT
    ├── build.sh                    # Linux/macOS build-and-run helper
    ├── build.ps1                   # Windows build-and-run helper
    ├── README.md                   # This file
    └── README_CN.md                # Chinese version
```

`Dockerfile` and `.dockerignore` are intentionally left at the repository root:

- `.github/workflows/docker-image.yml` builds with `context: .` and no `file:` argument, so it looks for `./Dockerfile`. Moving it requires updating the workflow.
- Docker only reads `.dockerignore` from the build context root. Placing it in a subdirectory fails **silently**, which would bake `.git/`, `auths/` and `config.yaml` into the image. There is no workaround for this one.

## 2. Before the first start

### 2.1 Create the config file

This is the one step that makes the first start fail outright if skipped:

```bash
cp config.example.yaml config.yaml
```

`config.yaml` is bind-mounted into the container. When the host path does not exist, Docker creates an **empty directory** with the same name, the container cannot read its config, and it enters a crash-restart loop. Recovering requires `rm -rf config.yaml` first, so it is easier to just `cp` up front.

### 2.2 Absolute `auth-dir` (recommended, not required)

```yaml
auth-dir: "/root/.cli-proxy-api"
```

The default works as-is: the image declares no `USER`, so the container runs as root, Docker injects `HOME=/root`, and `ResolveAuthDir` (`internal/util/util.go`) expands `~` to `/root/.cli-proxy-api`, which is exactly the volume mapping target.

Setting an absolute path removes the implicit dependency on `HOME`. If you run with `-u <uid>` for a UID that has no `/etc/passwd` entry, `HOME` becomes `/`, `~` resolves to `/.cli-proxy-api`, and credentials no longer land on the mount point.

There are two separate ways this fails the start, and both surface as a startup error rather than a silent misplacement:

- Resolution failure. `os.UserHomeDir()` only reads `$HOME` on Unix and returns an error when it is empty. `cmd/server/main.go` logs `failed to resolve auth directory` and returns before anything else starts.
- Resolution succeeds but the directory is unusable. The file watcher calls `watcher.Add(authDir)` (`internal/watcher/events.go`), whose error propagates up to `sdk/cliproxy/service_lifecycle.go` as `failed to start watcher`. This is the `/.cli-proxy-api` case above: an unprivileged UID cannot create that directory under `/`.

> Under systemd `HOME` is not injected by default, which is the case where it genuinely must be set explicitly. In containers Docker already provides it.

## 3. Quick start

Use the helper scripts. They already pin the Compose project directory:

```bash
./deploy/dev/build.sh      # Linux / macOS
```

```powershell
.\deploy\dev\build.ps1     # Windows
```

Option `1` pulls the published image (`eceasy/cli-proxy-api:latest`); option `2` builds from source and injects version information via `git describe`.

## 4. Running docker compose by hand

`--project-directory` is required. Relative volume paths resolve against the **Compose project directory**, *not* against the location of the Compose file. Run this from the repository root — both `-f` and `.` are relative paths:

```bash
docker compose \
  -f deploy/dev/docker-compose.yml \
  --project-directory . \
  up -d
```

Omit it and Compose treats `deploy/dev/` as the project directory, creating a second set of `config.yaml`, `auths/`, `logs/` and `plugins/` there. Verified with `docker compose config`:

| Invocation | Where volumes actually point |
|---|---|
| `-f deploy/dev/docker-compose.yml --project-directory .` | `<repo>/config.yaml` ✅ |
| `cd deploy/dev && docker compose -f docker-compose.yml` | `<repo>/deploy/dev/config.yaml` ❌ |

`build.context` behaves the same way. It is set to `.` and also resolves against the project directory, so pinning `--project-directory` to the repository root fixes the build context too.

> Changing `context` to `../..` to "correct" the path does not work: the context ends up outside the repository because it stacks with `--project-directory`. Use `context: .` together with `--project-directory`.

Verify the resolved configuration before starting:

```bash
docker compose -f deploy/dev/docker-compose.yml --project-directory . config
```

## 5. Volumes

| Host path | Container path | Purpose |
|---|---|---|
| `./config.yaml` | `/CLIProxyAPI/config.yaml` | Main config. Must exist as a file before the first start |
| `./auths` | `/root/.cli-proxy-api` | OAuth credentials. Must match `auth-dir` |
| `./logs` | `/CLIProxyAPI/logs` | Application logs |
| `./plugins` | `/CLIProxyAPI/plugins` | Optional shared-library plugins |

Override individually with `CLI_PROXY_CONFIG_PATH`, `CLI_PROXY_AUTH_PATH`, `CLI_PROXY_LOG_PATH` and `CLI_PROXY_PLUGIN_PATH`.

The `logs` mount stays empty by default because `logging-to-file` defaults to `false` and logs go to stdout (view them with `docker compose logs -f`). Set it to `true` to write files.

`ResolveLogDirectory` (`internal/logging/global_logger.go`) has two branches that bypass this mount point: `$WRITABLE_PATH/logs` wins whenever `WRITABLE_PATH` is set, and if the working-directory `logs` is not writable it falls back to `<auth-dir>/logs`, which lands in the `auths` mount instead. Neither triggers in the default setup, where the container runs as root and `logs` is mounted.

## 6. Ports

`8317` is the only port that is always required. The three OAuth callback ports are only needed while logging in to the matching provider through the management panel, and can be closed afterwards.

| Port | Purpose | Required |
|---|---|---|
| `8317` | Main API (OpenAI / Gemini / Claude compatible) plus management endpoints | Always |
| `54545` | Anthropic / Claude OAuth callback (`internal/auth/claude/anthropic_auth.go`) | When logging in to Claude |
| `1455` | Codex OAuth callback (`internal/auth/codex/openai_auth.go`, overridable with `--oauth-callback-port`) | When logging in to Codex |
| `51121` | Antigravity OAuth callback (`internal/auth/antigravity/constants.go`) | When logging in to Antigravity |
| `8085` | No listener in the codebase binds this; legacy mapping | Can be commented out |
| `11451` | No listener in the codebase binds this; legacy mapping | Can be commented out |

OAuth logins start from the management panel or the management API. There is no browser inside the container: you complete the authorization in your own browser, and the callback address is `http://localhost:<callback port>/...`, so that port must be reachable from the machine running the browser. The three callback ports are provider-specific and not interchangeable. Publishing only `1455` makes Claude and Antigravity logins fail, and the failure shows up as a timeout after roughly 5 minutes rather than an immediate error. Once the credential JSON lands in `auths/`, the file watcher picks it up without a container restart.

## 7. Updating

```bash
docker compose -f deploy/dev/docker-compose.yml --project-directory . pull
docker compose -f deploy/dev/docker-compose.yml --project-directory . up -d
```

Config, credentials and logs live on bind mounts, so swapping images does not lose them. Config changes are hot-reloaded by the file watcher; a restart is only needed when the watcher itself did not come up.

## 8. Cluster mode

`docker-compose.cluster.yml` joins a node to the [CLIProxyAPIHome](https://github.com/router-for-me/CLIProxyAPIHome) control plane. It requires `HOME_JWT` and **deliberately does not mount** `config.yaml`, because the configuration is pushed by Home.

```bash
export HOME_JWT="<jwt from Home>"
docker compose \
  -f deploy/dev/docker-compose.cluster.yml \
  --project-directory . \
  up -d
```

Its volumes are `./home` → `/root/.cli-proxy-api` plus the same `logs` and `plugins`. When `HOME_JWT` is empty the container prints `HOME_JWT is required` and exits.

See `.env.cluster.example` for how to obtain the JWT.

## 9. Images

Published by `.github/workflows/docker-image.yml` on every `v*` tag, as a multi-arch manifest covering `linux/amd64` and `linux/arm64`:

- `eceasy/cli-proxy-api:latest`
- `eceasy/cli-proxy-api:<tag>`

Run `docker login <registry>` before pulling from a private registry. Avoid passing `-u` / `-p` on the command line; let the credential helper store the session.

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Crash-restart loop complaining the config is missing | `config.yaml` did not exist and Docker created it as a directory | `rm -rf config.yaml && cp config.example.yaml config.yaml` |
| `failed to resolve auth directory` | `HOME` is empty, so `~` cannot be expanded | Set `auth-dir: "/root/.cli-proxy-api"` |
| `failed to start watcher` pointing at `/.cli-proxy-api` | Ran with `-u <uid>` for a UID without a passwd entry, so `HOME=/` shifted the `~` expansion | Same fix: use an absolute path |
| Claude / Antigravity login hangs then fails after ~5 minutes | Only `1455` was published; `54545` / `51121` were not | Publish the callback port for the provider, per the port table |
| Unexpected `config.yaml` / `auths/` under `deploy/dev/` | `--project-directory` was omitted | Delete them and rerun with `--project-directory .` |
| `COPY failed` during build | Build context resolved outside the repository | Run `docker compose config` and confirm `context` is the repository root |
| Credentials lost after an update | `auths/` not mounted, or `auth-dir` does not match the mount point | Point `auth-dir` at the in-container path `/root/.cli-proxy-api` |
| `logs/` stays empty | `logging-to-file` defaults to `false` | Use `docker compose logs -f`, or enable `logging-to-file` |
| `pull access denied` | Not logged in to the registry | `docker login <registry>` |
| `HOME_JWT is required` | Cluster mode started without a JWT | Export `HOME_JWT`, or use the single-node Compose file |
| `exec format error` | Image architecture does not match the host | Check `uname -m`; official images cover amd64/arm64 |
