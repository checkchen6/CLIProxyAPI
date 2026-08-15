# 部署流程

由 [`deploy.sh`](deploy.sh) 驱动的单节点 Docker 部署流程图。中文操作指南：[README_CN.md](README_CN.md)。

默认路径使用已发布的多架构镜像，**不需要构建步骤，也不需要在服务器上克隆此仓库**。只有在你携带本地改动时才需要构建自己的镜像。

---

## 1. 选择路径

```
                    你有本地代码改动吗？
                            |
             +--------------+--------------+
             | 没有                        | 有
             v                            v
    使用已发布的镜像               build-push.ps1
    eceasy/cli-proxy-api:<tag>            |
    (amd64 + arm64 manifest,      +-------+-------+
     每个 v* tag 一个)            |               |
             |                 默认推送          -Save
             |                    |               |
             |             私有 registry    dist/*.tar.gz
             |                    |               |
             |              服务器 pull     scp + docker load
             |                    |               |
             +----------+---------+---------------+
                        v
                    deploy.sh
```

`deploy.sh` 不假定使用官方镜像；在 `.env` 中将 `CLI_PROXY_IMAGE` 指向你自己的仓库即可。

---

## 2. 构建你自己的镜像（可选）

```
  Windows 工作站
  ─────────────
  .\deploy\docker\build-push.ps1          # 默认推送到阿里云 registry
  .\deploy\docker\build-push.ps1 -Local   # 只本地构建，不推送
  .\deploy\docker\build-push.ps1 -Save    # 导出 tar.gz
        |
        |  [frontend] bun install + bun run build (web/management)
        |             -> dist/index.html 复制到
        |                internal/managementasset/embedded/management.html
        |             (vite-plugin-singlefile 内联所有资源；
        |              用 -SkipFrontend 跳过，但需面板文件已存在)
        |
        |  [gate 1] gofmt -l            -> 任何输出都会阻止构建
        |  [gate 2] go build ./cmd/server -> 非零退出码阻止构建
        |            (通过 //go:embed 嵌入上面刷新的面板)
        |  [gate 3] BOM scan compose/config yaml -> 发现 BOM 则阻止
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
        +-- 默认 -> docker login <registry>  (无 -u/-p；仅凭据存储)
        |            docker push <ref>        (每次推送检查退出码)
        |
        +-- -Save -> docker save -o dist/<name>.tar
                     GZipStream -> dist/<name>.tar.gz
                     (docker save 使用 -o 写入，不用管道：PowerShell
                      管道是面向文本的，会损坏二进制流)
```

每个原生命令后面都有显式的 `$LASTEXITCODE` 检查。`$ErrorActionPreference = "Stop"` 不覆盖 Windows PowerShell 5.1 上的原生命令，所以仅依赖它会让失败的 `compose build` 继续进入 `up -d`。`deploy/dev/build.ps1` 以同样的方式防范这个问题，在其 `Invoke-Compose` 包装器内部。

---

## 3. 首次部署：从 systemd 二进制迁移

```
  scp deploy/docker/deploy.sh root@<server>:/root/
  ssh root@<server>
  chmod +x /root/deploy.sh
  /root/deploy.sh --version v7.2.118 --from-binary
        |
        v
  [preflight]
     docker 存在，daemon 可达
     compose 类型检测 (docker compose | docker-compose)
     uname -m 报告
        |
        v
  [scaffold]  /root/cliproxyapi-docker/
     mkdir auths/ logs/ plugins/
     render docker-compose.yml   (如果已存在则跳过)
     render .env                 (CLI_PROXY_VERSION 更新，旧副本备份)
        |
        v
  [stop legacy]                        <-- 提示确认
     systemctl stop cliproxyapi
     systemctl disable cliproxyapi
        |     仅 stop 不够：Restart=always 只覆盖崩溃，
        |     但启用的单元在下次启动时返回并重新占用 8317
        v
  [migrate payload]
     cp /root/cliproxyapi/config.yaml       -> ./config.yaml
     cp /root/cliproxyapi/config.yaml       -> *.bak.<stamp>
     cp -a /root/.cli-proxy-api             -> *.bak.<stamp>
     cp -a /root/.cli-proxy-api/.           -> ./auths/
        |
        v
  [audit config.yaml]                  <-- 警告提示是否继续
     offset 0 有 BOM？                      -> 阻止 YAML 解析
     host: 必须是 "" / 0.0.0.0 / ::         -> 回环值绑定容器 lo，
                                               发布的端口映射到空
     auth-dir: 必须到达 /root/.cli-proxy-api -> 否则凭据写入容器层
                                               并在重建时丢失
     port: 必须是 8317                      -> compose 映射容器端口
     allow-remote: false                    -> 信息性；Docker SNAT 使
                                               主机 curl 非本地
        |
        v
  [start]
     docker compose pull
     docker compose up -d --remove-orphans
        |
        v
  [verify]
     docker inspect  -> State.Status == running
     docker logs     -> "CLIProxyAPI Version: ..." 横幅
                        (在标志解析前由 main() 打印，所以是构建的
                         自己的声明而不是标签猜测)
     ss -tlnH        -> 必须是 127.0.0.1:8317，不是 0.0.0.0:8317
     curl /v1/models -> 期望 200，使用第一个 api-keys 条目
```

`ss` 行是最重要的验收检查。Docker 在 `DOCKER` 链中安装其 DNAT 规则，iptables **在** `INPUT` 之前遍历，所以 `0.0.0.0` 发布不被 ufw、firewalld 或控制面板防火墙覆盖。API 密钥将是唯一挡在它前面的东西。

回滚保持低成本，因为旧二进制文件、其版本目录和 unit 文件都留在原处：

```
  cd /root/cliproxyapi-docker && docker compose down
  systemctl enable --now cliproxyapi
```

---

## 4. 日常升级

```
  选项 A - 重新运行脚本
  ─────────────────────
  /root/deploy.sh --version v7.2.119
        |
        |  compose 文件：保持不变（已存在）
        |  .env: CLI_PROXY_VERSION 更新，之前的副本保留为 .env.bak.<stamp>
        |  遗留迁移：跳过（无 --from-binary）
        v
  pull -> up -d -> verify


  选项 B - 手动
  ─────────────
  cd /root/cliproxyapi-docker
  vi .env                      # CLI_PROXY_VERSION=v7.2.119
  docker compose pull
  docker compose up -d
  docker compose logs -f --tail 50
```

两条路径都是非破坏性的：`config.yaml`、`auths/`、`logs/` 和 `plugins/` 都位于容器外的绑定挂载上。

配置编辑由文件观察器捕获，无需重启。只有在观察器本身启动失败时才需要重启。

---

## 5. 请求路由

```
  客户端 (浏览器, IDE, SDK)
        |
        |  HTTPS, 公共 DNS
        v
  主机反向代理 (控制面板 Nginx, Caddy, ...)
    - 终止 TLS
    - 设置 X-Forwarded-For
        |
        |  proxy_pass http://127.0.0.1:8317
        v
  Docker 发布端口  127.0.0.1:8317 -> 容器 8317
    - DOCKER 链中的 DNAT
    - SNAT 将源地址重写为网桥网关 (172.x.0.1)
        |
        v
  容器中的 CLIProxyAPI，监听 0.0.0.0:8317
    - config.yaml 中的 host: "" 使此绑定成为可能
        |
        +-- /v1/*, /v1beta/*  -> 提供商 API，由 api-keys 保护
        +-- /v0/management/*  -> 管理 API，由 secret-key 保护
        |        并且当调用者不是 127.0.0.1/::1 时由 allow-remote 保护
        |
        |   c.ClientIP() 遵循 X-Forwarded-For，因为没有 SetTrustedProxies
        |   调用缩小 Gin 信任每个代理的默认设置。因此通过反向代理的
        |   请求携带真实客户端地址，永远不会被视为本地。
        v
  上游提供商 (Gemini / Claude / Codex / ...)
```

OAuth 回调端口（`54545` Claude, `1455` Codex, `51121` Antigravity）在生成的 compose 文件中被注释掉。从早期部署继承的凭据继续工作，所以只有在添加新提供商账户时才需要它们。当需要时，取消注释你需要的单个端口，并通过 SSH 隧道访问它：

```
  ssh -L 54545:127.0.0.1:54545 root@<server>
```

回调在**你的**浏览器中落在 `http://localhost:<port>/...`，所以端口必须从你的工作站可达，而不是从互联网。这三个端口是提供商特定的，不可互换；缺少的端口在大约五分钟后超时失败，而不是立即出错。

---

## 6. 数据持久化

```
  /root/cliproxyapi-docker/            (主机)                容器
  |
  +-- docker-compose.yml     渲染一次，然后由你编辑
  +-- .env                   CLI_PROXY_IMAGE / VERSION / BIND / PORT
  |
  +-- config.yaml       <-->  /CLIProxyAPI/config.yaml
  |     必须在首次启动前作为文件存在。当路径缺失时 Docker 创建同名
  |     目录，这会变成需要 `rm -rf config.yaml` 清理的崩溃循环。
  |
  +-- auths/            <-->  /root/.cli-proxy-api
  |     OAuth 凭据。必须匹配 `auth-dir`。文件观察器捕获新凭据文件
  |     无需重启。
  |
  +-- logs/             <-->  /CLIProxyAPI/logs
  |     除非 `logging-to-file: true` 否则为空；默认是 stdout，用
  |     `docker compose logs -f` 读取。注意 ResolveLogDirectory 在
  |     设置 $WRITABLE_PATH 时优先使用 $WRITABLE_PATH/logs，会绕过
  |     此挂载。
  |
  +-- plugins/          <-->  /CLIProxyAPI/plugins
        可选的共享库插件。

  deploy.sh 保留的备份（永不自动清理）：
    ./config.yaml.bak.<stamp>              迁移时替换的现有配置
    ./.env.bak.<stamp>                     版本更新
    /root/cliproxyapi/config.yaml.bak.<stamp>
    /root/.cli-proxy-api.bak.<stamp>
```

没有数据库和缓存服务。本地文件存储是默认的，完全不需要环境变量；Postgres、git 和对象存储后端通过 [`.env.example`](../../.env.example) 中记录的 `PGSTORE_*`、`GITSTORE_*` 和 `OBJECTSTORE_*` 变量选入。
