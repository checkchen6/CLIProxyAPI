# 自托管生产部署

这个目录放的是**服务器部署资产**，是本仓库新增的 —— 上游没有 `deploy/` 目录。这里的脚本默认值针对具体某台服务器写的，不适合提到上游。

> 命名说明：`deploy/docker/`（本目录）是往服务器上正式部署用的；`deploy/dev/` 是上游那套在开发机上跑起来看看的脚本，上游原本散在仓库根目录（`docker-build.sh`、`docker-compose.yml` 等），本仓库把它们收拢进了 `deploy/dev/`。

流程图见 [deploy-flow.md](deploy-flow.md)。容器本身的通用知识（`config.yaml` 必须先建成文件、`auth-dir` 解析、端口用途、故障排查表）见 [../dev/README_CN.md](../dev/README_CN.md)，本文不重复。

## 和 `deploy/dev/` 的分工

两个目录不是新旧关系，是**受众不同**。

`deploy/dev/` 面向**开发机**：你有仓库 checkout，想在自己机器上把它跑起来看看，或者从源码构建验证改动。

`deploy/docker/` 面向**服务器**：长期对外提供服务，前面挂着反向代理，需要可控的升级和回滚。

| | `deploy/dev/` | `deploy/docker/` |
|---|---|---|
| 跑在哪 | 开发机，需要仓库 checkout | 服务器，单文件，不需要仓库 |
| 目的 | 跑起来看看 / 源码构建验证 | 长期稳定提供服务 |
| compose 文件 | 仓库里那份，带 `build:` 段 | `deploy.sh` 运行时渲染，无 `build:` 段 |
| 镜像 tag | `latest` + `pull_policy: always` | 强制显式 pin，拒绝 `latest` |
| 端口绑定 | `0.0.0.0:8317` | `127.0.0.1:8317`（可配） |
| OAuth 回调端口 | 三个全开 | 默认全关，按需开单个 |
| Compose project 目录 | 必须 `--project-directory` 指到仓库根 | compose 与数据同目录，不需要 |
| 配置体检 | 无 | host / auth-dir / port / BOM 四项 |
| 迁移旧的二进制部署 | 无 | `--from-binary` |
| 部署后验证 | 无 | 状态 / 版本 / 绑定地址 / HTTP 200 |
| 是否适合进上游 | 是，内容通用 | 否，默认值环境特定 |

`deploy/dev/` 那三个选择（`latest`、`pull_policy: always`、`0.0.0.0`）在它自己的定位下是对的：开发机就是要拉最新的、就是要从宿主机任意地址访问。把它直接搬到生产才是问题 —— 每次 `up -d` 都会被动升级，而 `0.0.0.0` 会绕过宿主机防火墙。

依赖方向是单向的：本目录引用 `deploy/dev/`，反过来不引用。所以 `deploy/dev/` 可以独立提 PR。

## 该用哪个

```
你在哪台机器上？
  |
  +-- 开发机
  |     |
  |     +-- 只想跑起来看看        -> deploy/dev/build.sh 或 build.ps1，选 1
  |     +-- 想验证自己的代码改动  -> deploy/dev/build.sh 或 build.ps1，选 2
  |     +-- 要出一个私有镜像发到服务器 -> deploy/docker/build-push.ps1
  |
  +-- 服务器
        |
        +-- 首次部署 / 从二进制迁过来 -> deploy/docker/deploy.sh --from-binary
        +-- 日常升级版本             -> deploy/docker/deploy.sh --version vX.Y.Z
        +-- 接入 Home 控制面（集群） -> deploy/dev/docker-compose.cluster.yml
```

## 文件说明

### `deploy.sh` — 服务器侧部署

自包含。服务器上不需要这个仓库，`scp` 这一个文件过去就能跑。它会在部署目录里渲染 `docker-compose.yml` 和 `.env`，**只在文件不存在时渲染**，之后你在服务器上的手改会保留。

```bash
scp deploy/docker/deploy.sh root@<服务器>:/root/
ssh root@<服务器>
chmod +x /root/deploy.sh

# 先空跑，把要执行的每条命令原样打印出来
/root/deploy.sh --version v7.2.118 --from-binary --dry-run

# 核对无误后真跑
/root/deploy.sh --version v7.2.118 --from-binary
```

`--from-binary` 是一次性迁移开关：停掉并 disable 旧的 systemd 单元、备份、把 `config.yaml` 和凭据目录搬进部署目录。日常升级不要带它：

```bash
/root/deploy.sh --version v7.2.119
```

停服务、覆盖已有 `config.yaml`、覆盖非空 `auths/` 三处都会停下来问，不会闷头执行。旧二进制、版本目录、unit 文件全部留在原地，回滚是：

```bash
cd /root/cliproxyapi-docker && docker compose down
systemctl enable --now cliproxyapi
```

默认值都可以用参数或环境变量改，`--help` 有完整列表：

| 参数 / 环境变量 | 默认值 |
|---|---|
| `--deploy-dir` / `CLI_PROXY_DEPLOY_DIR` | `/root/cliproxyapi-docker` |
| `--legacy-dir` / `CLI_PROXY_LEGACY_DIR` | `/root/cliproxyapi` |
| `--legacy-auth-dir` / `CLI_PROXY_LEGACY_AUTH_DIR` | `/root/.cli-proxy-api` |
| `--service` / `CLI_PROXY_SERVICE` | `cliproxyapi` |
| `--bind` / `CLI_PROXY_BIND` | `127.0.0.1` |
| `--port` / `CLI_PROXY_PORT` | `8317` |
| `CLI_PROXY_IMAGE` | `registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api` |

`--version` 没有默认值，必填，且显式拒绝 `latest`。原因是这个部署要的是"升级由我决定"，而不是"每次重启撞到当时的最新版"。

### `build-push.ps1` — 出私有镜像

**只有当你有本地代码改动时才需要。** 工作区和上游一致时，直接用官方发布的多架构镜像（`eceasy/cli-proxy-api:<tag>`，由 `.github/workflows/docker-image.yml` 在每个 `v*` tag 上构建），跳过这个脚本。

构建前三道阻断式检查，任一不过就停：

1. `gofmt -l` 有输出 → 停（AGENTS.md 要求 Go 改动后必须 gofmt）
2. `go build ./cmd/server` 非零 → 停（AGENTS.md 要求改动后必须验证编译）
3. compose / config YAML 带 UTF-8 BOM → 停（BOM 会让 YAML 解析在第一个键上失败，而这些文件不经过任何 Dockerfile 的 sed 清理）

两种交付方式：

```powershell
# 推私有 registry
.\deploy\docker\build-push.ps1 -Push -Registry registry.cn-hangzhou.aliyuncs.com -Namespace 你的命名空间

# 没有 registry 就导出 tar.gz，scp 过去 docker load
.\deploy\docker\build-push.ps1 -Save
```

两种方式跑完都会打印服务器侧要执行的后续命令。

版本号取自 `git describe --tags --always --dirty`，跟随仓库既有的 tag 体系，不引入独立的 VERSION 文件（那会出现两个版本号真源）。

### `deploy-flow.md` — 流程图

6 张 ASCII 图：路径选择、构建交付、首次迁移、日常升级、请求路由、数据持久化。改了脚本记得同步更新。

## 已知的坑

这三条是这套脚本专门在防的，展开在 [deploy-flow.md](deploy-flow.md)：

**端口绑 `0.0.0.0` 会绕过宿主机防火墙。** Docker 把 DNAT 规则装在 `DOCKER` 链，iptables 遍历它**早于** `INPUT`，所以 ufw / firewalld / 面板防火墙的放行规则管不到已发布的容器端口。`deploy.sh` 部署完会用 `ss` 实测一次绑定地址，看到 `0.0.0.0` 就告警。

**`config.yaml` 里 `host` 写了回环地址，容器就起不来。** 容器内进程只会绑容器自己的 `lo`，宿主机的端口映射打到空处，表现是服务像完全死了。容器场景下 `host` 必须留空，暴露面靠端口绑定地址控制。`deploy.sh` 会体检这一项。

**`allow-remote: false` 时，在服务器上直接 curl 管理接口会 403。** `internal/api/handlers/management/handler.go` 里 `localClient` 是拿 `c.ClientIP()` 和 `127.0.0.1` / `::1` 做字面比较，而 Docker 的 SNAT 会把源地址改写成网桥网关（`172.x.0.1`）。经反向代理进来的请求不受影响 —— 生产代码没有调 `SetTrustedProxies`，走 Gin 默认信任全部代理，`X-Forwarded-For` 里的真实客户端 IP 本来就不是回环。
