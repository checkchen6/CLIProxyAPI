# Docker 部署手册

CLIProxyAPI 的 Docker 部署说明。镜像里只有一个 Go 单二进制，没有 Web 服务器、没有进程管理器、也没有数据库需要初始化。

English version: [README.md](README.md)。服务器层面的其他话题（受限地区的出海代理、域名反代 HTTPS、防火墙放行、客户端接入）见仓库根目录的 [DEPLOYMENT_CN.md](../../DEPLOYMENT_CN.md)。

## 一、目录结构

```
<仓库根目录>/
├── Dockerfile              # 留在根目录：发布 workflow 用 context "." 构建
├── .dockerignore           # 必须留在根目录：Docker 只从构建上下文根目录读取
└── deploy/dev/
    ├── docker-compose.yml          # 单机部署
    ├── docker-compose.cluster.yml  # 集群模式，由 Home JWT 驱动
    ├── build.sh                    # Linux/macOS 构建运行脚本
    ├── build.ps1                   # Windows 构建运行脚本
    ├── README.md                   # 英文版
    └── README_CN.md                # 本文件
```

`Dockerfile` 和 `.dockerignore` 是有意留在根目录的：

- `.github/workflows/docker-image.yml` 用 `context: .` 构建且没有 `file:` 参数，会去找 `./Dockerfile`。移动它必须同步改 workflow。
- Docker 只从构建上下文根目录读 `.dockerignore`。放进子目录会**静默失效**，导致 `.git/`、`auths/`、`config.yaml` 全被打进镜像。这一条没有变通办法。

## 二、启动前必做

### 1. 创建配置文件

这是唯一一个跳过就会导致首次启动直接失败的步骤：

```bash
cp config.example.yaml config.yaml
```

`config.yaml` 是 bind mount 挂载进容器的。宿主机路径不存在时，Docker 会自动创建一个**同名空目录**，容器读不到配置、崩溃重启循环。修复要先 `rm -rf config.yaml` 再建文件，所以不如一开始就 `cp`。

### 2. auth-dir 建议写绝对路径（推荐，非必须）

```yaml
auth-dir: "/root/.cli-proxy-api"
```

按默认方式跑不改也能用：镜像没有 `USER` 指令，容器以 root 运行，Docker 会注入 `HOME=/root`，`ResolveAuthDir`（`internal/util/util.go`）里的 `~` 展开成 `/root/.cli-proxy-api`，恰好等于 `docker-compose.yml` 的 volume 映射目标。

写成绝对路径的价值在于去掉对 `HOME` 的隐式依赖：一旦用 `-u <uid>` 以自定义 UID 运行，而该 UID 在 `/etc/passwd` 里没有条目，`HOME` 会变成 `/`，`~` 解析结果偏移到 `/.cli-proxy-api`，凭据就不再落在挂载点上。

有两条独立的失败路径，都表现为启动阶段报错，而不是凭据被静默写错位置：

- **解析失败**：`os.UserHomeDir()` 在 Unix 上只读 `$HOME`，`HOME` 为空时直接返回错误。`cmd/server/main.go` 打印 `failed to resolve auth directory` 后直接返回，后面什么都不会启动。
- **解析成功但目录不可用**：文件监听器会 `watcher.Add(authDir)`（`internal/watcher/events.go`），该错误一路上抛到 `sdk/cliproxy/service_lifecycle.go`，以 `failed to start watcher` 终止启动。上面 `/.cli-proxy-api` 就是这种情况——非 root UID 在 `/` 下建不了目录。

> systemd 部署下 `HOME` 默认不注入，那种场景才真的必须显式给出（见根目录部署手册的 `Environment=HOME=/root`）。容器场景 Docker 已经帮你注入了。

## 三、快速启动

用封装脚本，它已经帮你固定了 Compose 的 project 目录：

```bash
./deploy/dev/build.sh      # Linux / macOS
```

```powershell
.\deploy\dev\build.ps1     # Windows
```

选项 `1` 拉取已发布镜像（`eceasy/cli-proxy-api:latest`）；选项 `2` 从源码构建，并通过 `git describe` 注入版本信息。

## 四、手动执行 docker compose

必须带 `--project-directory`。volume 的相对路径是按 **Compose project 目录**解析的，**不是**按编排文件所在目录。以下命令要在仓库根目录执行——`-f` 和 `.` 都是相对路径：

```bash
docker compose \
  -f deploy/dev/docker-compose.yml \
  --project-directory . \
  up -d
```

漏掉 `--project-directory`，Compose 会把 `deploy/dev/` 当成 project 目录，在里面另生成一套 `config.yaml`、`auths/`、`logs/`、`plugins/`。用 `docker compose config` 实测对比：

| 执行方式 | volume 实际指向 |
|---|---|
| `-f deploy/dev/docker-compose.yml --project-directory .` | `<仓库>/config.yaml` ✅ |
| `cd deploy/dev && docker compose -f docker-compose.yml` | `<仓库>/deploy/dev/config.yaml` ❌ |

`build.context` 同理。它设为 `.`，也是按 project 目录解析，所以把 `--project-directory` 固定到仓库根目录，构建上下文也就对了。

> 曾经试过把 `context` 改成 `../..` 来「修正」路径，结果 context 被解析到仓库外面（`E:\Jetbrains\vscode2024`），因为它和 `--project-directory` 叠加了。正确做法是 `context: .` 配合 `--project-directory`。

启动前先验证解析结果：

```bash
docker compose -f deploy/dev/docker-compose.yml --project-directory . config
```

## 五、Volume 挂载

| 宿主机路径 | 容器路径 | 用途 |
|---|---|---|
| `./config.yaml` | `/CLIProxyAPI/config.yaml` | 主配置。首次启动前必须已存在且是文件 |
| `./auths` | `/root/.cli-proxy-api` | OAuth 凭据。必须和 `auth-dir` 一致 |
| `./logs` | `/CLIProxyAPI/logs` | 应用日志 |
| `./plugins` | `/CLIProxyAPI/plugins` | 可选的动态库插件 |

可用 `CLI_PROXY_CONFIG_PATH`、`CLI_PROXY_AUTH_PATH`、`CLI_PROXY_LOG_PATH`、`CLI_PROXY_PLUGIN_PATH` 分别覆盖。

`logs` 挂载默认是空的，因为 `logging-to-file` 默认 `false`，日志走 stdout（用 `docker compose logs -f` 看）。设成 `true` 才会写文件。

`ResolveLogDirectory`（`internal/logging/global_logger.go`）有两条分支会绕过这个挂载点：`WRITABLE_PATH` 有值时优先用 `$WRITABLE_PATH/logs`；工作目录下的 `logs` 不可写时退到 `<auth-dir>/logs`，那会落进 `auths` 挂载而不是 `logs`。默认部署（容器以 root 运行、`logs` 已挂载）两条都不会命中。

## 六、端口

`8317` 是唯一始终必需的端口。三个 OAuth 回调端口只在通过管理面板登录对应厂商账号时需要可达，登录完成后可以关掉。

| 端口 | 用途 | 是否必需 |
|---|---|---|
| `8317` | 主 API（OpenAI / Gemini / Claude 兼容）+ 管理接口 | 必需 |
| `54545` | Anthropic / Claude OAuth 回调（`internal/auth/claude/anthropic_auth.go`） | 登录 Claude 时必需 |
| `1455` | Codex OAuth 回调（`internal/auth/codex/openai_auth.go`，可用 `--oauth-callback-port` 覆盖） | 登录 Codex 时必需 |
| `51121` | Antigravity OAuth 回调（`internal/auth/antigravity/constants.go`） | 登录 Antigravity 时必需 |
| `8085` | 代码中没有对应监听，属历史遗留映射 | 可注释 |
| `11451` | 代码中没有对应监听，属历史遗留映射 | 可注释 |

OAuth 登录从管理面板或管理 API 发起。容器里没有浏览器：授权在你自己机器的浏览器里完成，回调地址是 `http://localhost:<回调端口>/...`，所以对应端口必须从你的浏览器所在机器可达。三个回调端口各归各家，不能互相替代——只放行 `1455` 就登不了 Claude 和 Antigravity，而且失败表现是等约 5 分钟后超时，不是立即报错。凭据 JSON 落到 `auths/` 后，文件监听器会自动识别，不需要重启容器。

## 七、更新

```bash
docker compose -f deploy/dev/docker-compose.yml --project-directory . pull
docker compose -f deploy/dev/docker-compose.yml --project-directory . up -d
```

配置、凭据、日志都在 bind mount 上，换镜像不会丢。配置改动由文件监听器热重载，只有监听器本身没起来时才需要重启。

## 八、集群模式

`docker-compose.cluster.yml` 让节点接入 [CLIProxyAPIHome](https://github.com/router-for-me/CLIProxyAPIHome) 控制面。它需要 `HOME_JWT`，并且**故意不挂载** `config.yaml`——配置由 Home 下发。

```bash
export HOME_JWT="<从 Home 获取的 jwt>"
docker compose \
  -f deploy/dev/docker-compose.cluster.yml \
  --project-directory . \
  up -d
```

它的 volume 是 `./home` → `/root/.cli-proxy-api`，加上同样的 `logs` 和 `plugins`。`HOME_JWT` 为空时容器会输出 `HOME_JWT is required` 并退出。

获取 JWT 的方式见 `.env.cluster.example`。

## 九、镜像

由 `.github/workflows/docker-image.yml` 在每个 `v*` tag 上发布，多架构 manifest 覆盖 `linux/amd64` 和 `linux/arm64`：

- `eceasy/cli-proxy-api:latest`
- `eceasy/cli-proxy-api:<tag>`

拉私有仓库镜像前先 `docker login <registry>`。不要在命令行传 `-u` / `-p`，让凭据管理器保存登录态。

## 十、故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 容器崩溃重启循环，报配置找不到 | `config.yaml` 之前不存在，被 Docker 创建成了目录 | `rm -rf config.yaml && cp config.example.yaml config.yaml` |
| `failed to resolve auth directory` | `HOME` 为空，`~` 无法展开 | 改成 `auth-dir: "/root/.cli-proxy-api"` |
| `failed to start watcher`，指向 `/.cli-proxy-api` | 用了 `-u <uid>` 且该 UID 无 passwd 条目，`HOME=/` 使 `~` 解析偏移 | 同上，改成绝对路径 |
| 登录 Claude / Antigravity 卡住约 5 分钟后失败 | 只放行了 `1455`，`54545` / `51121` 未发布 | 按端口表放行对应厂商的回调端口 |
| `deploy/dev/` 下莫名多出 `config.yaml` / `auths/` | 漏了 `--project-directory` | 删掉它们，加上 `--project-directory .` 重新执行 |
| 构建时 `COPY failed` | 构建上下文解析到了仓库外面 | 跑 `docker compose config`，确认 `context` 是仓库根目录 |
| 更新后凭据丢失 | `auths/` 没挂载，或 `auth-dir` 和挂载点不一致 | 让 `auth-dir` 对上容器内路径 `/root/.cli-proxy-api` |
| `logs/` 一直是空的 | `logging-to-file` 默认 `false` | 用 `docker compose logs -f`，或开启 `logging-to-file` |
| `pull access denied` | 没登录镜像仓库 | `docker login <registry>` |
| `HOME_JWT is required` | 集群模式没给 JWT | 导出 `HOME_JWT`，或改用单机编排文件 |
| `exec format error` | 镜像架构和服务器不匹配 | 确认服务器 `uname -m`，官方镜像已覆盖 amd64/arm64 |
