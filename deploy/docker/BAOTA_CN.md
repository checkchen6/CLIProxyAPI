# 宝塔面板部署手册（Docker 方式）

用宝塔面板做反向代理和 HTTPS，CLIProxyAPI 本体跑在 Docker 容器里。适合已经装了宝塔、习惯用面板管站点和证书的服务器。

- 部署脚本与配置模板：本目录（`deploy/docker/`）
- 流程图：[deploy-flow.md](deploy-flow.md)
- 通用部署说明（含 systemd 方式、服务器地区选择、出海代理）：[../../DEPLOYMENT_CN.md](../../DEPLOYMENT_CN.md)

> 服务器地区决定成败：香港/国内 IP 会被 OpenAI、Claude 拦截，需要给服务器配出海代理。详见 [DEPLOYMENT_CN.md 第一节](../../DEPLOYMENT_CN.md)。本手册只讲部署链路，不重复这部分。

---

## 一、架构与端口

```
客户端 / IDE / SDK
      |
      |  HTTPS  https://api.your-domain.com
      v
宝塔 Nginx（443）
  - 终止 TLS，签发和续期证书
  - 反向代理到 127.0.0.1:8317
      |
      v
Docker 发布端口 127.0.0.1:8317 -> 容器 8317
      |
      v
容器内 CLIProxyAPI 监听 0.0.0.0:8317
      |
      v
上游厂商（Gemini / Claude / Codex / xAI ...）
```

对外只开 443、80（证书续期用）、22。**8317 不对公网开放**，只绑在本机回环上由宝塔反代。

### 为什么必须绑 127.0.0.1

Docker 把 DNAT 规则装在 iptables 的 `DOCKER` 链，这条链的遍历**早于** `INPUT`。所以一旦端口发布成 `0.0.0.0:8317`，宝塔的端口规则、ufw、firewalld 全都管不住它，等于直接裸奔在公网，只剩 API key 挡着。

配置上由 `.env` 里的 `CLI_PROXY_BIND=127.0.0.1` 控制。

---

## 二、与 systemd 二进制部署的关键差异

同一个配置项，两种部署方式的正确值**正好相反**，这是迁移过来最容易踩的坑：

| 配置项 | systemd 二进制部署 | Docker 部署 |
|---|---|---|
| `config.yaml` 里的 `host` | `127.0.0.1` | **必须留空 `""`** |
| 暴露面由谁控制 | `host` 字段 | `.env` 的 `CLI_PROXY_BIND` |
| `auth-dir` | `/root/.cli-proxy-api` | `/root/.cli-proxy-api`（须与卷挂载一致） |

容器里的进程如果把 `host` 写成 `127.0.0.1`，它只会绑**容器自己**的回环网卡，宿主机的端口映射就打到了空处。现象是服务看起来完全没响应，日志却一切正常。

---

## 三、前置准备

- 一台 Linux 服务器（Ubuntu 20.04+ / Debian 11+ / CentOS 8+ 均可），已装宝塔面板
- 一个已解析到该服务器的域名（DNS 加一条 A 记录，`nslookup 你的域名` 能返回服务器 IP）
- root 或 sudo 权限

宝塔侧先放行端口：**面板 → 安全 → 端口规则**，确保 `80`、`443`、`22` 已放行。云服务器还要在**云控制台安全组**同样放行，两层是叠加关系，都通才算通。

---

## 四、安装 Docker

宝塔应用商店里有「Docker 管理器」，装上即可；也可以直接用官方脚本（更省事，且自带 compose 插件）：

```bash
curl -fsSL https://get.docker.com | bash
systemctl enable --now docker

# 验证，两条都要有输出
docker version
docker compose version
```

如果 `docker compose version` 报错但 `docker-compose version` 可用，说明是老版本的独立 compose，后面命令把 `docker compose` 换成 `docker-compose` 即可。

---

## 五、登录私有镜像仓库

镜像推在阿里云私有仓库时，服务器需要先登录一次，凭据会记在本机：

```bash
docker login registry.cn-hangzhou.aliyuncs.com
# 依次输入阿里云用户名和「容器镜像服务」的访问凭证密码
```

用官方公开镜像（`eceasy/cli-proxy-api`）则不需要这一步。

---

## 六、准备部署目录与配置

有两条路：**自动**（推荐）和**手动**。

### 方式 A：用 deploy.sh 自动生成（推荐）

`deploy.sh` 是自包含的，服务器上不需要克隆仓库，传一个文件过去就能跑。它会建目录、渲染 `docker-compose.yml` 和 `.env`、体检 `config.yaml`、拉镜像、起容器并验证。

在**本地**执行：

```bash
scp deploy/docker/deploy.sh root@你的服务器IP:/root/
```

到服务器上：

```bash
chmod +x /root/deploy.sh

# 先空跑，把要执行的命令原样打印出来核对
/root/deploy.sh --dry-run

# 核对无误后真跑
/root/deploy.sh
```

不带参数就是部署私有镜像的 `:latest`。镜像仓库（`registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api`）和 tag（`latest`）都是脚本内置的默认值，日常不用指定。

首次运行时脚本会自动生成 `config.yaml`，并随机生成 API key 和管理密钥，直接打印在终端上：

```
[warn] Generated credentials -- copy them now, the secret-key is shown only once:
         api-key    (for clients)      : sk-xxxxxxxx...
         secret-key (management panel) : xxxxxxxx...
```

**当场把这两个值存好。** `secret-key` 在首次启动后会被 bcrypt 哈希写回文件，明文再也拿不回来（忘了就改成新的明文值重启，会重新哈希）。

生成的配置已经按容器场景设好了 `host: ""`、`auth-dir`、`allow-remote: true`，不需要你再调。后续重跑脚本不会覆盖这个文件，手改都会保留。

要锁定某个具体构建（回滚、或验证特定版本）就显式给 tag：

```bash
/root/deploy.sh --version v7.2.118-205-g02bcabf
```

换别的镜像仓库时用环境变量覆盖：

```bash
CLI_PROXY_IMAGE=你的仓库地址 /root/deploy.sh
```

> `latest` 是浮动 tag，这里要清楚它的两种行为：脚本每次运行都会显式 `docker compose pull`，所以**跑一次脚本就会更新到最新构建**；而渲染出的 compose 用的是 `pull_policy: missing`，所以**容器重启或服务器重启只会复用本地镜像**，不会因为仓库连不上而起不来，也不会在你没预期的时候偷偷换版本。

首次运行后 `config.yaml` 还是模板值，需要按下面「关键配置项」改一遍，再 `docker compose up -d` 重启。

### 方式 B：手动复制模板

在**本地**执行，注意目标文件名要去掉 `.example`：

```bash
ssh root@你的服务器IP "mkdir -p /root/cliproxyapi-docker/{auths,logs,plugins}"

scp deploy/docker/templates/docker-compose.example.yml root@你的服务器IP:/root/cliproxyapi-docker/docker-compose.yml
scp deploy/docker/templates/.env.example              root@你的服务器IP:/root/cliproxyapi-docker/.env
scp deploy/docker/templates/config.example.yaml       root@你的服务器IP:/root/cliproxyapi-docker/config.yaml
```

### 关键配置项

**`.env`**：

```bash
CLI_PROXY_IMAGE=registry.cn-hangzhou.aliyuncs.com/wgyc/cli-proxy-api
CLI_PROXY_VERSION=latest     # 默认值；要锁版本就改成具体 tag，如 v7.2.118
CLI_PROXY_BIND=127.0.0.1     # 生产保持回环，别改成 0.0.0.0
CLI_PROXY_PORT=8317
TZ=Asia/Shanghai
```

**`config.yaml`** 这几项必须对：

```yaml
host: ""                          # 容器场景必须留空
port: 8317                        # 与 compose 映射的容器端口一致

auth-dir: "/root/.cli-proxy-api"  # 必须与卷挂载目标一致，否则凭据丢在容器层

remote-management:
  allow-remote: true              # 通过域名用管理面板必须开，见第十节
  secret-key: "换成强随机密码"     # 管理面板登录密钥

api-keys:
  - "换成强随机的 key"             # 客户端调用用的密钥
```

三个硬性约束，不满足就起不来或者用不了：

- `config.yaml` 必须**先以文件形式存在**。路径不存在时 Docker 会建一个同名**目录**，然后进入崩溃循环，得 `rm -rf config.yaml` 才能恢复。
- `api-keys` 不能留 `your-api-key-1`、`your-api-key-2`、`your-api-key-3` 这三个字面值。命中会触发安全模式，所有代理端点被禁用，只能打开面板改配置。
- 文件**不能带 UTF-8 BOM**，否则 YAML 解析在第一个键上就失败。用 Windows 记事本存过的文件尤其注意，检查：`head -c 3 config.yaml | od -An -tx1`，出现 `ef bb bf` 就是有 BOM。

> **`secret-key` 启动后会变成一串乱码，这是正常的。** 服务检测到明文密钥时会用 bcrypt 哈希它，并把哈希值写回 `config.yaml`（注释和其他内容都会保留），避免每次启动重复计算。文件里看到的 `$2a$10$...` 就是哈希结果。
>
> 所以：**明文密钥只在你写进去的那一刻可见，之后要自己记住**。忘了就改回一个新的明文值，重启后会重新哈希。

---

## 七、启动容器并本地验证

```bash
cd /root/cliproxyapi-docker
docker compose pull
docker compose up -d

# 状态应为 running
docker compose ps

# 日志里应有 "CLIProxyAPI Version: ..." 横幅
docker compose logs --tail 50
```

三项验证，全过再去配反代：

```bash
# 1. 绑定地址必须是 127.0.0.1:8317，不能是 0.0.0.0:8317
ss -tlnp | grep 8317

# 2. 接口应返回 200 和模型列表
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer 你的api-key" \
  http://127.0.0.1:8317/v1/models

# 3. 面板页面应返回 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8317/management.html
```

这一步不通就不要往下走，反代只会把问题盖住，变成一个更难查的 502。

---

## 八、宝塔建站与反向代理

1. **网站 → 添加站点**：域名填你的域名，类型选纯静态，不要数据库、不要 PHP。
2. **站点设置 → 反向代理 → 添加反向代理**：
   - 目标 URL：`http://127.0.0.1:8317`
   - 发送域名：`$host`

宝塔生成的反代配置需要确认包含这几项（缺了会出问题，尤其是流式和 WebSocket）：

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# 流式响应（SSE）必须关缓冲，否则输出会被攒着一次性吐出
proxy_buffering off;
proxy_request_buffering off;

# 长连接和长响应
proxy_read_timeout 600s;
proxy_connect_timeout 75s;
proxy_send_timeout 600s;

# 上传大文件（多模态请求）时放宽
client_max_body_size 100M;
```

完整参考配置见 [templates/nginx.example.conf](templates/nginx.example.conf)。宝塔用户通常在面板里改就够了，不必替换整份文件。

---

## 九、WebSocket 支持（Codex 需要）

反代 location 里必须有：

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

宝塔在开启「WebSocket 支持」时会自动带上，并在 http 段加 `map` 定义。改完务必验证：

```bash
nginx -t
```

- 输出 `successful`：配置没问题，`nginx -s reload` 生效
- 报 `unknown "connection_upgrade" variable`：说明 `map` 没定义，在 nginx 的 http 段补一行

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
```

也可以退一步写成 `proxy_set_header Connection "upgrade";`，不依赖 `map`，代价是非 WebSocket 请求也会带上这个头。

---

## 十、申请 HTTPS

**站点设置 → SSL → Let's Encrypt** → 勾选域名 → 申请，成功后开启「强制 HTTPS」。

申请失败绝大多数是两个原因：80 端口没放行（云安全组或宝塔漏了），或者 DNS 还没生效。先 `nslookup 你的域名` 确认解析，再重试。

---

## 十一、管理面板与添加提供商账号

面板地址是 `/management.html`：

```
https://api.your-domain.com/management.html
```

注意不是 `/v0/management/`——那是管理 **API** 的前缀，直接用浏览器打开只会看到接口报错。

### allow-remote 必须开（Docker 场景的硬约束）

管理接口的鉴权逻辑是把请求源 IP 和 `127.0.0.1` / `::1` 做**字面比较**，只有相等才算「本地客户端」；不是本地客户端时，`allow-remote: false` 会直接返回 403 `remote management disabled`。

Docker 部署下这个判断几乎永远不成立：

- 经宝塔反代进来：代码没有调用 `SetTrustedProxies`，Gin 默认信任全部代理，取到的是 `X-Forwarded-For` 里你的**真实公网 IP**
- 在服务器上直接 `curl 127.0.0.1:8317`：Docker 的 SNAT 会把源地址改写成网桥网关 `172.x.0.1`
- 通过 SSH 隧道访问：同样经过端口映射，同样被 SNAT 改写

所以想用管理面板，`allow-remote` 必须是 `true`。这不是「不安全的偷懒选项」，而是这个部署形态下的唯一可行值。安全性靠下面三层补：

1. `secret-key` 用强随机值，所有管理请求（含本地）都要带它
2. 只经 HTTPS 暴露，不开放 8317 到公网
3. 在宝塔反代里对管理路径加 IP 白名单（下面给配置）

连续 5 次密钥错误会触发 30 分钟的 IP 封禁，可以挡住暴力猜测。

### 给管理路径加 IP 白名单（推荐）

在宝塔站点的配置文件里，反代 location **之前**插入两段：

```nginx
location = /management.html {
    allow 你的公网IP;
    deny all;
    proxy_pass http://127.0.0.1:8317;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location /v0/management/ {
    allow 你的公网IP;
    deny all;
    proxy_pass http://127.0.0.1:8317;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

这样即使密钥泄露，管理接口也只对你的 IP 开放。公网 IP 会变的话就别加，靠强密钥 + HTTPS。

改完照例 `nginx -t && nginx -s reload`。

### 用环境变量代替配置文件里的密钥（可选）

不想把密钥写进 `config.yaml` 的话，可以用 `MANAGEMENT_PASSWORD` 环境变量。设置它会有两个效果：值直接作为管理密钥，**并且强制开启远程管理**（无视配置文件里的 `allow-remote: false`）。

需要手动在 `docker-compose.yml` 的 `environment` 段加一行：

```yaml
    environment:
      TZ: ${TZ:-Asia/Shanghai}
      MANAGEMENT_PASSWORD: ${MANAGEMENT_PASSWORD}
```

再在 `.env` 里写 `MANAGEMENT_PASSWORD=强随机密码`，然后 `docker compose up -d`。

因为它会强制打开远程管理，用之前先确认 IP 白名单或强密钥已经到位。

### 添加提供商账号

API key 类的提供商（Gemini、Claude、Codex、xAI、OpenRouter 等）直接在面板里填 key 即可，或者写进 `config.yaml`。

OAuth 类账号需要回调端口，compose 里默认全部注释掉了。要加账号时：

1. 编辑 `docker-compose.yml`，取消注释你需要的**那一个**端口：

```yaml
      - "${CLI_PROXY_BIND:-127.0.0.1}:54545:54545"  # Anthropic / Claude
      # - "${CLI_PROXY_BIND:-127.0.0.1}:1455:1455"    # Codex
      # - "${CLI_PROXY_BIND:-127.0.0.1}:51121:51121"  # Antigravity
```

2. `docker compose up -d` 生效
3. 在**本地**建 SSH 隧道（回调是落在你自己浏览器的 `localhost` 上，所以端口要对你的机器可达，而不是对公网）：

```bash
ssh -L 54545:127.0.0.1:54545 root@你的服务器IP
```

4. 在面板里走完 OAuth 流程，凭据会自动落到 `auths/` 目录，文件监听器会直接加载，不用重启
5. 加完把端口重新注释掉，`docker compose up -d`

三个端口是各家专用的，不能互换。用错端口的表现是等大约五分钟后超时，而不是立刻报错。

---

## 十二、日常运维

### 升级版本

```bash
ssh root@你的服务器IP
/root/deploy.sh
```

用默认的 `latest` 时，重跑脚本就会拉到最新构建。要升到某个指定版本就加 `--version v7.2.119`。

脚本会更新 `.env`（旧的存成 `.env.bak.<时间戳>`）、拉镜像、重建容器、验证。手动等价操作：

```bash
cd /root/cliproxyapi-docker
vi .env                    # 改 CLI_PROXY_VERSION
docker compose pull
docker compose up -d
docker compose logs -f --tail 50
```

升级期间宝塔反代会短暂返回 502，属正常。

### 改配置

`config.yaml` 的改动由文件监听器自动加载，不用重启。只有监听器本身没起来时才需要 `docker compose restart`。

### 日志

默认输出到 stdout，用 `docker compose logs -f` 看。`logging-to-file: true` 时才会写进 `logs/` 目录。

### 备份

要备份的就两样，都在部署目录里：

```bash
cd /root/cliproxyapi-docker
tar czf ~/cliproxyapi-backup-$(date +%Y%m%d-%H%M%S).tar.gz config.yaml auths/
```

`config.yaml` 是配置，`auths/` 是 OAuth 凭据，丢了要重新授权所有账号。

### 回滚

用 `latest` 的代价就在回滚上——它不记录你之前跑的是哪个构建。所以回滚要显式指定版本：

```bash
/root/deploy.sh --version v7.2.118
```

或者手动改 `.env` 里的 `CLI_PROXY_VERSION` 再 `docker compose pull && docker compose up -d`。数据都在宿主机的绑定挂载上，容器重建不会丢。

想知道当前跑的到底是哪个构建：

```bash
docker logs cli-proxy-api 2>&1 | grep -m1 'CLIProxyAPI Version:'
```

这行是程序自己打印的版本，比镜像 tag 可靠。**升级前先记下它**，需要回滚时才有目标可回。

---

## 十三、排查表

| 现象 | 原因 | 处理 |
|---|---|---|
| 宝塔反代返回 502 | 容器没起来，或没监听 `127.0.0.1:8317` | `docker compose ps` 看状态，`ss -tlnp \| grep 8317` 看绑定 |
| 容器起来又立刻退出 | `config.yaml` 里 `host` 写了 `127.0.0.1` | 改成 `host: ""` |
| 容器反复重启，报路径相关错误 | `config.yaml` 被 Docker 建成了目录 | `rm -rf config.yaml`，重新放好文件再起 |
| 日志报 YAML 解析失败在第一行 | 文件带 UTF-8 BOM | `sed -i '1s/^\xEF\xBB\xBF//' config.yaml` |
| 接口返回 `unsafe_example_api_key` | `api-keys` 还是 `your-api-key-N` 模板值 | 改成强随机 key |
| 打开 `/v0/management/` 报接口错误 | 面板路径不对 | 用 `/management.html` |
| 面板报 403 `remote management disabled` | `allow-remote: false` | 改成 `true`，见第十一节 |
| 面板报 403 且提示 IP 被封 | 连续 5 次密钥错误 | 等 30 分钟，或重启容器清掉计数 |
| 重启后凭据全没了，要重新登录 | `auth-dir` 与卷挂载不一致 | 改成 `/root/.cli-proxy-api` |
| Codex 连不上 / 流式断开 | 反代缺 WebSocket 配置 | 见第九节，检查 `nginx -t` |
| 流式响应卡住后一次性吐出 | 反代没关缓冲 | 加 `proxy_buffering off;` |
| `ss` 显示 `0.0.0.0:8317` | `CLI_PROXY_BIND` 不是回环 | 改 `.env` 为 `127.0.0.1`，`docker compose up -d` |
| Let's Encrypt 申请失败 | 80 没放行或 DNS 未生效 | 查安全组和宝塔端口规则，`nslookup` 验证解析 |
| 调 AI 返回 Cloudflare 拦截页 | 服务器 IP 所在地区被厂商封 | 给服务器配出海代理，见 DEPLOYMENT_CN.md |

---

## 十四、安全检查清单

上线前过一遍：

- [ ] `ss -tlnp | grep 8317` 显示的是 `127.0.0.1`，不是 `0.0.0.0`
- [ ] 云安全组和宝塔端口规则里，`8317` **没有**对公网放行
- [ ] 对外只开 443、80、22
- [ ] `secret-key` 和 `api-keys` 都是强随机值，且没在截图、聊天记录里泄露过
- [ ] 站点已开启强制 HTTPS
- [ ] 管理路径加了 IP 白名单（公网 IP 固定的话）
- [ ] OAuth 回调端口用完已重新注释
- [ ] `config.yaml` 和 `auths/` 已备份
