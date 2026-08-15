# 自托管生产部署

这个目录放的是**服务器部署资产**，是本仓库新增的 —— 上游没有 `deploy/` 目录。这里的脚本默认值针对具体某台服务器写的，不适合提到上游。

> 命名说明：`deploy/docker/`（本目录）是往服务器上正式部署用的；`deploy/dev/` 是上游那套在开发机上跑起来看看的脚本，上游原本散在仓库根目录（`docker-build.sh`、`docker-compose.yml` 等），本仓库把它们收拢进了 `deploy/dev/`。

用宝塔面板做反代和 HTTPS 的话，直接看 [BAOTA_CN.md](BAOTA_CN.md)，那份是从零到上线的完整步骤。

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
| 镜像 tag | `latest` + `pull_policy: always` | 默认 `latest` + `pull_policy: missing`，可显式 pin |
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

### 服务器部署完整教程

### 场景 1：从零开始全新部署

**前置条件**：
- 一台 Linux 服务器（Ubuntu 20.04+ / Debian 11+ / CentOS 8+）
- Docker 和 Docker Compose 已安装
- 有 root 权限

**步骤 1：准备部署脚本**

在*本地工作站**执行：

```bash
# 上传部署脚本到服务器
scp deploy/docker/deploy.sh root@你的服务器IP:/root/
```
**步骤 2：配置文件（脚本会自动生成，通常无需手工准备）**

首次运行 `deploy.sh` 时会自动渲染 `config.yaml`，并随机生成 API key 和管理密钥打印在终端上——务必当场存下来，`secret-key` 首次启动后会被 bcrypt 哈希写回文件，明文无法恢复。后续重跑不会覆盖该文件。

只有想预先审查或自定义时才需要手工准备，模板见 [templates/config.example.yaml](templates/config.example.yaml)。核心字段如下，注意 `allow-remote` 和 `secret-key` 都在 `remote-management` 下面，不是顶层：

```yaml
host: ""                          # 容器场景必须留空
port: 8317                        # 容器内监听端口
auth-dir: "/root/.cli-proxy-api"  # 凭据目录，必须匹配 compose 挂载

remote-management:
  allow-remote: true              # Docker 场景必须开，原因见「已知的坑」
  secret-key: "换成强随机密码"     # 管理面板密钥

api-keys:
  - "换成强随机的 key"             # 客户端调用密钥，至少一个
```

提供商账号不在这里手写，部署完成后通过管理面板添加即可。

上传到服务器：

```bash
scp config.yaml root@你的服务器IP:/root/
```

**步骤 3：SH 登录服务器执行部署**

```bash
ssh root@你的服务器IP

# 赋予执行权限
chmod +x /root/deploy.sh
# 先空跑检查（推荐）
/root/deploy.sh --version v7.2.118 --dry-run

# 确认无误后真正部署
/root/deploy.sh --version v7.2.118
```

脚本会自动：
- 检测 Docker 环境
- 创建 `/root/cliproxyapi-docker/` 部署目录
- 渲染 `docker-compose.yml` 和 `.env`
- 将你上传的 `config.yaml` 移动到部署目录
- 拉取镜像并启动容器
- 验证服务状态

**步骤 4：验证部署**

```bash
# 查看容器状态
cd /root/cliproxyapi-docker
docker compose ps

# 查看日志
docker compose logs -f

# 测试 API（使用 config.yaml 里的第一个 api-key）
curl http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer sk-test-key-12345"
```

看到 200 响应和模型列表即为成功。

**步骤 5：配置反向代理（Nginx 示例）**

```nginx
server {
  listen 443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

  location / {
        proxy_pass http://127.0.0.1:8317;
        proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
        
     # WebSocket 支持（Codex 需要）
      proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
     proxy_set_header Connection "upgrade";
    
       # 超时设置
      proxy_read_timeout 300s;
       proxy_connect_timeout 75s;
   }
}
```

重载 Nginx：
```bash
nginx -t && nginx -s reload
```
**步骤 6：通过管理面板添加提供商账号**

1. 浏览器访问 `https://api.yourdomain.com/management.html`（`/v0/management/` 是 API 前缀，不是面板页面）
2. 使用 `config.yaml` 里的 `secret-key` 登录
3. 点击「Add Provider」添加 Claude / Gemini / OpenAI 等账号
4. OAuth 流程完成后，凭据自动保存到 `auths/` 目录
---

### 场景 2：从旧的 systemd 二进制部署迁移
**前置条件**：
- 已有 systemd 单元 `cliproxyapi.service` 在运行
- 配置文件在 `/root/cliproxyapi/config.yaml`
- 凭据目录在 `/root/.cli-proxy-api/`

**步骤 1：备份现有配置（可选但推荐）**

```bash
tar czf /root/cliproxyapi-backup-$(date +%Y%m%d-%H%M%S).tar.gz \
  /root/cliproxyapi/ \
  /root/.cli-proxy-api/
```

**步骤 2：上传部署脚本**

```bash
# 在本地工作站执行
scp deploy/docker/deploy.sh root@你的服务器IP:/root/
```

**步骤 3：执行迁移**

```bash
ssh root@你的服务器IP
chmod +x /root/deploy.sh

# 先空跑检查
/root/deploy.sh --version v7.2.118 --from-binary --dry-run
# 确认无误后执行迁移
/root/deploy.sh --version v7.2.118 --from-binary
```

脚本会**交互式确认**以下操作：
1. 停止并禁用 `cliproxyapi.service`
2. 检查 `config.yaml` 配置项（host / port / auth-dir / BOM）
3. 迁移 `config.yaml` 和 `auths/` 到部署目录

**步骤 4：验证迁移结果**

```bash
# 检查旧服务已停止
systemctl status cliproxyapi  # 应显示 inactive + disabled

# 检查新容器运行正常
cd /root/cliproxyapi-docker
docker compose ps
docker compose logs --tail 50

# 测试 API
curl http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer $(grep -m1 'api-keys:' config.yaml -A1 | tail -1 | awk '{print $2}')"
```

**回滚方案**：

如果迁移有问题，回滚到旧部署：

```bash
cd /root/cliproxyapi-docker && docker compose down
systemctl enable --now cliproxyapi
```

旧二进制、配置和凭据都保持原样，可以无缝回滚。

---

### 场景 3：日常版本升级
**方式 A：使用脚本升级（推荐）**

```bash
ssh root@你的服务器IP
/root/deploy.sh --version v7.2.119
```

脚本会自动：
- 更新 `.env` 中的 `CLI_PROXY_VERSION`（旧版本自动备份为 `.env.bak.<时间戳>`）
- 拉取新版本镜像
- 重启容器
- 验证服务状态

**方式 B：手动升级**

```bash
ssh root@你的服务器IP
cd /root/cliproxyapi-docker
# 编辑 .env 文件
vi .env
# 修改 CLI_PROXY_VERSION=v7.2.119

# 拉取并重启
docker compose pull
docker compose up -d

# 查看日志确认新版本
docker compose logs -f --tail 50
```

---

### 场景 4：使用自己构建的私有镜像

**当你有本地代码改动时，需要先在本地构建私有镜像。**

**步骤 1：在本地工作站构建并推送**
```powershell
# Windows PowerShell
cd e:\Jetbrains\vscode2024\githubspace\CLIProxyAPI

# 推送到阿里云（默认）
.\deploy\dockeruild-push.ps1

# 或推送到其他 registry
.\deploy\docker\build-push.ps1 -Registry your-registry.com -Namespace your-namespace

# 或导出为 tar.gz（无 registry 时）
.\deploy\docker\build-push.ps1 -Save
```

**步骤 2A：使用 registry 拉取（推荐）**

修改服务器上的 `.env`：

```bash
ssh root@你的服务器IP
cd /root/cliproxyapi-docker
vi .env
```

修改以下两行：

```bash
CLI_PROXY_IMAGE=registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api
CLI_PROXY_VERSION=v7.2.118-205-g02bcabf  # 替换为你的版本号
```

拉取并重启：

```bash
docker compose pull
docker compose up -d
```

**步骤 2B：使用 tar.gz 加载（无 registry 时）**

```bash
# 在本地工作站上传
scp dist/cli-proxy-api-v7.2.118-205-g02bcabf.tar.gz root@你的服务器IP:/tmp/

# SSH 登录服务器
ssh root@你的服务器IP

# 加载镜像
gunzip -c /tmp/cli-proxy-api-v7.2.118-205-g02bcabf.tar.gz | docker load

# 更新 .env
cd /root/cliproxyapi-docker
vi .env
# 修改 CLI_PROXY_IMAGE 和 CLI_PROXY_VERSION

# 重启容器
docker compose up -d
```
---

## 常见问题排查
**问题 1：容器启动后立即退出**

```bash
# 查看详细日志
docker compose logs

# 常见原因：
# - config.yaml 中 host 写了 127.0.0.1（必须留空或 0.0.0.0）
# - config.yaml 带 UTF-8 BOM（用 hexdump -C config.yaml | head -1 检查）
# - auth-dir 路径不匹配 compose 挂载
```

**问题 2：管理面板 403 Forbidden**

```bash
# 原因：allow-remote: false。Docker 场景下源 IP 永远不是回环：
#   - 服务器本地 curl：被 Docker SNAT 改写成网桥网关 172.x.0.1
#   - 经反向代理：取到 X-Forwarded-For 里的真实公网 IP
# 走反代并不能绕过这个判定，必须开 allow-remote。
# 解决：config.yaml 里 remote-management.allow-remote 改为 true，
#      配强 secret-key，并在反代层给管理路径加 IP 白名单。
```

**问题 3：OAuth 回调超时**

```bash
# 原因：回调端口未暴露或 SSH 隧道未建立
# 解决方案：
cd /root/cliproxyapi-docker
vi docker-compose.yml
# 取消注释需要的回调端口（54545 Claude / 1455 Codex / 51121 Antigravity）
docker compose up -d

# 然后在本地工作站建立 SSH 隧道：
ssh -L 54545:127.0.0.1:54545 root@你的服务器IP
```

**问题 4：端口被占用**

```bash
# 检查占用
ss -tlnp | grep 8317

# 如果是旧的 systemd 服务未停止
systemctl stop cliproxyapi
systemctl disable cliproxyapi
```

---

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
| `CLI_PROXY_VERSION` | `latest` |

`--version` 默认 `latest`，直接 `./deploy.sh` 就是部署私有镜像的最新构建。要锁定某个构建（回滚、验证特定版本）时再显式传 tag。

`latest` 的两种行为要分清：

- 脚本每次运行都会显式 `docker compose pull`，所以**重跑脚本 = 更新到最新构建**
- 渲染出的 compose 是 `pull_policy: missing`，所以**容器重启 / 服务器重启只复用本地镜像**，不会因为仓库连不上而起不来，也不会在你没预期的时候换版本

代价是 `latest` 不记录你之前跑的是哪个构建，回滚必须显式给 tag。升级前先记一下当前版本：

```bash
docker logs cli-proxy-api 2>&1 | grep -m1 'CLIProxyAPI Version:'
```

### `build-push.ps1` — 出私有镜像

**只有当你有本地代码改动时才需要。** 工作区和上游一致时，直接用官方发布的多架构镜像（`eceasy/cli-proxy-api:<tag>`，由 `.github/workflows/docker-image.yml` 在每个 `v*` tag 上构建），跳过这个脚本。

构建前三道阻断式检查，任一不过就停：

1. `gofmt -l` 有输出 → 停（AGENTS.md 要求 Go 改动后必须 gofmt）
2. `go build ./cmd/server` 非零 → 停（AGENTS.md 要求改动后必须验证编译）
3. compose / config YAML 带 UTF-8 BOM → 停（BOM 会让 YAML 解析在第一个键上失败，而这些文件不经过任何 Dockerfile 的 sed 清理）

两种交付方式：

```powershell
# 默认就推私有 registry，并同时打 :<version> 和 :latest 两个 tag
.\deploy\docker\build-push.ps1

# 只本地构建，不推送
.\deploy\docker\build-push.ps1 -Local

# 换 registry / namespace
.\deploy\docker\build-push.ps1 -Registry registry.cn-hangzhou.aliyuncs.com -Namespace 你的命名空间

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

**`allow-remote: false` 时，在服务器上直接 curl 管理接口会 403。** `internal/api/handlers/management/handler.go` 里 `localClient` 是拿 `c.ClientIP()` 和 `127.0.0.1` / `::1` 做字面比较，而 Docker 的 SNAT 会把源地址改写成网桥网关（`172.x.0.1`）。经反向代理进来的请求同样不算本地 —— 生产代码没有调 `SetTrustedProxies`，走 Gin 默认信任全部代理，`X-Forwarded-For` 里的真实客户端 IP 本来就不是回环。所以走反代并不能绕过这个判定：**Docker 部署下要用管理接口，`allow-remote` 必须为 `true`**，安全性靠强 `secret-key`、只经 HTTPS 暴露、反代层 IP 白名单来兜。
