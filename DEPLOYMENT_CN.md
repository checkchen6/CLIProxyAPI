# CLIProxyAPI 部署手册

服务器部署 CLIProxyAPI + Windows EasyCLI 远程管理的完整流程。本手册记录了实际部署中踩过的坑，新服务器照着走即可。

## 一、先搞懂数据流向（最重要，决定服务器选哪）

```
客户端/EasyCLI ──→ 服务器上的CLIProxyAPI ──→ (可选出海代理) ──→ Google / OpenAI / Anthropic
    (管理/调用)         (真正干活的)                              (最终的AI服务)
```

三段链路，任何一段断都用不了：

1. **客户端 ↔ 服务器**：管理流量（EasyCLI 改配置、发起登录）和调用流量（客户端调 AI）。
2. **服务器 ↔ AI 厂商**：所有实际请求（OAuth 换 token、token 刷新、AI 调用）**都由服务器发起**，不是你本地电脑。
3. 所以：**服务器所在地区必须能被 AI 厂商接受**，光你本地能连服务器不够。

### 地区现实（血泪教训）

| 服务器地区 | 结果 |
|---|---|
| 国内 | GitHub 下载都难，OpenAI/Claude/Gemini 全部直连不了 → 必须配出海代理 |
| 香港 | GitHub 能连，但 **OpenAI/Claude 会封香港 IP**（返回 Cloudflare "Unable to load site" 拦截页）→ 仍需美国出口代理 |
| 美国/日本等 | 直连各家 AI，最省心，`proxy-url` 留空即可 |

**结论：能用美国 VPS 就用美国 VPS，一劳永逸。** 用香港/国内则必须给服务器配一个出口在支持地区的代理（见第六节）。

---

## 二、下载安装（实践一）

```bash
curl -fsSL https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash
```

装到 `/root/cliproxyapi/`。下载失败（卡住/超时，curl 92 错误）说明网络不行，用镜像手动下：

```bash
cd /root && mkdir -p cliproxyapi && cd cliproxyapi
curl -L -o cli.tar.gz https://github.com/router-for-me/CLIProxyAPI/releases/latest/download/CLIProxyAPI_<版本>_linux_amd64.tar.gz
tar -xzf cli.tar.gz && chmod +x cli-proxy-api
```

> ⚠️ 脚本末尾的 `systemctl --user` 在 root 下会报 `Failed to connect to bus`，**属正常，忽略**。下面用系统级服务。

## 三、生成密钥（实践二）

```bash
echo "secret-key: $(openssl rand -hex 24)"
echo "api-key: sk-$(openssl rand -hex 24)"
```

- **secret-key** → EasyCLI Remote 连接/管理时填这个
- **api-keys** → 客户端调 AI 接口时填这个（也是 Codex 配置里的 bearer token）

## 四、写配置（实践三）

```bash
nano /root/cliproxyapi/config.yaml
```

关键项（**auth-dir 必须写绝对路径，这是崩溃重启的头号坑点**）：

> ⚠️ 下面的 `host: "0.0.0.0"` + `allow-remote: true` 会把**管理接口**（`/v0/management/*`，含可整体覆写配置的 `PUT /v0/management/config.yaml`）直接暴露到公网，且走 HTTP 明文——secret-key 在传输途中可被中间人读取。这里这样写只是为了先用 `http://IP:8317` 把链路打通、便于排查。
>
> 打通之后请务必按第十六节改成 `host: "127.0.0.1"` + 反向代理 HTTPS，或至少按第七节把云安全组的来源 IP 收窄到你自己的公网 IP。不要让 `0.0.0.0` + 来源 `0.0.0.0/0` 的组合长期留在生产上。

```yaml
host: "0.0.0.0"                     # ← 监听全部网卡，管理接口会暴露到公网；打通后按第十六节改回 127.0.0.1
port: 8317

remote-management:
  allow-remote: true
  secret-key: "步骤3生成的secret-key"

auth-dir: "/root/.cli-proxy-api"    # ← 必须绝对路径，不能用 ~

api-keys:
  - "步骤3生成的api-key"

# 受限地区（国内/香港）才需要，出口填支持地区（美国等）的代理，见第六节
# proxy-url: "socks5h://user:pass@proxy-host:port"

debug: false
```

## 五、建系统级 systemd 服务（实践四）

**关键：必须加 `Environment=HOME=/root`，否则程序解析不了 auth-dir，会崩溃重启循环、端口打不开。**

```bash
cat > /etc/systemd/system/cliproxyapi.service << 'EOF'
[Unit]
Description=CLIProxyAPI Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/cliproxyapi
ExecStart=/root/cliproxyapi/cli-proxy-api
Environment=HOME=/root
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cliproxyapi
systemctl status cliproxyapi --no-pager
```

验证：

```bash
ss -tlnp | grep 8317                    # 应看到 8317 在监听
curl -H "Authorization: Bearer <secret-key>" http://127.0.0.1:8317/v0/management/config
```

返回 JSON = 成功。出问题看日志：`journalctl -u cliproxyapi -n 50 --no-pager`

---

## 六、出海代理配置（国内/香港服务器必做）（实践六）

判断依据：调用 AI 时返回 OpenAI 的 **Cloudflare 拦截页**（`Unable to load site` + 服务器 IP + `If you are using a VPN, try turning it off`），或客户端报 `429 Too Many Requests`，就是服务器 IP 被厂商封了。

### 情况 A：已有现成的 SOCKS5 / HTTP 代理（最省事）

有些机场订阅提供**裸 SOCKS5 节点**，分享链接形如：

```
socks://<base64(user:pass)>@host:port#备注
```

解码 base64 得到 `user:pass`，直接拼成 proxy-url（CPA 原生支持 socks5/http，**无需装任何代理客户端**）：

```yaml
proxy-url: "socks5h://user:pass@host:port"
```

> 用 `socks5h` 让 DNS 也走代理更稳；若 CPA 启动报错不认，改用 `socks5://`。

### 情况 B：只有 vmess/vless/trojan 节点

需在服务器上跑 sing-box/xray 把节点转成本地 socks5 端口，再 `proxy-url: "socks5://127.0.0.1:本地端口"`。较麻烦，能拿到裸 socks 就优先用情况 A。

### 上代理前必须先验证（在服务器上跑）

```bash
# 1. 确认出口是支持地区的 IP（如美国）
curl -x socks5h://user:pass@host:port https://api.ipify.org --max-time 15

# 2. 确认能到 OpenAI（返回 HTTP 状态即可，PDX 等美国边缘节点说明走对了）
curl -x socks5h://user:pass@host:port -I https://api.openai.com --max-time 15
```

第 1 条返回支持地区 IP、第 2 条不再是 "Unable to load site" 拦截页，才算代理可用。

### 填入 CPA

- EasyCLI 界面：Basic Setting → Proxy URL 框填好 → Apply（**热重载，无需重启**）
- 或改 config.yaml 的 `proxy-url` → `systemctl restart cliproxyapi`

### 代理生效优先级

CLIProxyAPI 选择出口代理时，按以下顺序处理：

```text
账号/凭据级 proxy_url（最高） > config.yaml 全局 proxy-url > 服务器直连
```

1. OAuth 账号凭据文件中存在非空的 `proxy_url` 时，该账号只使用自己的代理，**不会使用全局代理**。
2. 账号没有配置 `proxy_url` 或该值为空时，回退使用 `config.yaml` 的全局 `proxy-url`。
3. 两级都未配置时，才使用服务器本机网络直连上游。

因此，EasyCLI 的 Basic Setting → Proxy URL 和 `config.yaml` 的 `proxy-url` 都只是在修改**全局代理**，不能覆盖账号凭据中已有的 `proxy_url`。出现“Claude/Codex 已走新代理，但某个 Gemini 账号仍走旧出口”时，应先检查该账号的凭据文件，而不是反复修改全局配置。

OAuth 凭据 JSON 位于 `auth-dir`（本手册为 `/root/.cli-proxy-api/`）；检查或编辑时只处理 `proxy_url` 字段，不要输出或复制同文件中的 access token、refresh token。官方配置项说明也将顶层 `proxy-url` 定义为全局代理，将 Provider 凭据中的 `proxy-url` 定义为单凭据覆盖项，见 [Configuration Options](https://help.router-for.me/configuration/options)。

---

## 七、放行端口（三层，缺一不可）

1. **云控制台安全组**：入方向 TCP `8317`，授权 IP 填**你自己的公网 IP**（查 https://myip.ipip.net）
2. **宝塔面板 → 安全 → 放行端口**：加 `8317`（装了宝塔必做，实时生效不用重启）
3. 无宝塔时才用系统防火墙：`firewall-cmd --add-port=8317/tcp --permanent && firewall-cmd --reload`

> 云安全组（服务器外）+ 系统/宝塔防火墙（服务器内）是叠加关系，都放行才通。装了宝塔用宝塔那个即可，别和 firewall-cmd 重复。

外部验证（Windows PowerShell）：

```powershell
curl.exe http://<服务器IP>:8317/v0/management/config -H "Authorization: Bearer <secret-key>"
```

返回 JSON = 外部通。超时=端口没放行；refused=安全组没生效。

---

## 八、EasyCLI 远程管理 + 登录 AI 账号

1. EasyCLI → **Remote** → 地址 `http://<服务器IP>:8317` → 管理密钥填 secret-key → Connect
2. 左侧 **Authentication Files** → 选服务（Codex/Claude/Gemini）发起 OAuth 登录 → 用本地浏览器完成授权 → 凭证自动存回服务器
3. 登录成功后，`GET /v1/models` 能列出该家模型即代表账号可用

> ⚠️ Basic Setting 页的 Secret Key 框是空的，点 Apply 不会清空 secret-key（API 不允许改该项），但填 Proxy URL 等其他项时留意别误改。

---

## 九、客户端接入

CPA 本质是 OpenAI 兼容接口。任意支持 OpenAI 格式的工具填：

- Base URL：`http://<服务器IP>:8317/v1`
- API Key：你的 api-keys（`sk-...`）
- 模型名：`/v1/models` 里实际存在的，如 `gpt-5.5`、`claude-sonnet-4-5-...`、`gemini-2.5-pro`

### Codex CLI 接入（OAuth 模式，推荐）

编辑 `~/.codex/config.toml`（Windows 为 `C:\Users\<用户>\.codex\config.toml`）：

```toml
model = "gpt-5.5"
model_provider = "cliproxyapi"
model_reasoning_effort = "high"
supports_websockets = true

[model_providers.cliproxyapi]
base_url = "http://<服务器IP>:8317/v1"     # 远程服务器填公网IP，不是127.0.0.1
experimental_bearer_token = "sk-你的apikey" # api-key，不是 secret-key
name = "cliproxyapi"
wire_api = "responses"
requires_openai_auth = true
```

OAuth 模式无需改 `~/.codex/auth.json`。

### 端到端验证

```powershell
curl.exe -X POST http://<服务器IP>:8317/v1/responses -H "Authorization: Bearer sk-你的apikey" -H "Content-Type: application/json" -d "{\"model\":\"gpt-5.5\",\"input\":\"hello\"}"
```

返回含 `"text":"Hello!..."`、`"status":"completed"` = 全链路打通。

---

## 十、安全清单（务必做）

- [ ] secret-key、api-keys 用强随机，不外泄（若曾在聊天/截图中暴露，重新生成）
- [ ] 安全组和宝塔来源 IP 收窄到自己，不用 `0.0.0.0/0`
- [ ] 更稳：`host` 保持 `127.0.0.1` 不暴露公网，用 SSH 隧道，EasyCLI/客户端连 `http://127.0.0.1:8317`
  ```bash
  ssh -L 8317:localhost:8317 root@<服务器IP>
  ```
- [ ] 有条件上 TLS 或 Nginx 反代 HTTPS
- [ ] 裸 SOCKS 代理是明文传输，长期用建议换加密方案

> `remote-management.allow-remote` 和 `secret-key` 除了直接改配置文件，也能通过 `PUT /v0/management/config.yaml` 覆盖——该接口整体写入 YAML，对这两个字段没有额外保护。这意味着一个泄露的 secret-key 可以自我续期并打开远程访问，所以 secret-key 一旦怀疑外泄就要立刻重置。单项 PUT 接口（如 `/v0/management/debug`）不涉及这两个字段。
> 明文 secret-key 首次启动自动 bcrypt 加密写回配置文件（`internal/config/config_load.go`），属正常。连续 5 次密钥错误临时封禁约 30 分钟。

---

## 十一、常用运维命令

```bash
systemctl restart cliproxyapi                 # 改配置后重启（EasyCLI 改的会热重载，无需手动重启）
systemctl disable --now cliproxyapi           # 禁用
systemctl status cliproxyapi                  # 看状态
journalctl -u cliproxyapi -f                  # 实时看日志
grep proxy-url /root/cliproxyapi/config.yaml  # 核对代理是否写入
~/cliproxyapi/cliproxyapi-installer upgrade   # 升级（保留配置）
```

---

## 十二、踩坑速查表

| 现象 | 原因 | 解决 |
|---|---|---|
| 下载卡住/超时（curl 92） | 服务器连不上 GitHub | 换支持地区服务器，或镜像/代理下载 |
| `Failed to connect to bus` | root 下用了 `systemctl --user` | 改用系统级服务（第五节） |
| 服务 running 但端口 refused | `$HOME is not defined`，崩溃重启循环 | 加 `Environment=HOME=/root` + auth-dir 写绝对路径 |
| EasyCLI/客户端外部连不上服务器 | 端口某层没放行 | 检查云安全组 + 宝塔两处 |
| 客户端报 `error sending request` | **本地 VPN(v2rayN 等)劫持了发往服务器 IP 的请求** | 在 VPN 里给服务器 IP 加直连规则，或临时关 VPN |
| 调用 AI 返回 Cloudflare `Unable to load site`（带服务器 IP） | **服务器 IP 被厂商按地区封锁**（香港/国内） | 给服务器配美国等支持地区的出口代理（第六节） |
| 调用报 `429 Too Many Requests` | 同上，重试后被限流/拦截的表现 | 同上，配出海代理 |
| 模型不存在 | 模型名填错 | `/v1/models` 查实际可用名 |

---

## 十三、本次实战链路（参考）

```
Windows客户端(关VPN或加直连规则)
   → 香港服务器 CLIProxyAPI (host:0.0.0.0 port:8317)
      → SOCKS5 代理 (美国出口 <proxy-ip>)
         → OpenAI ✅
```

关键点回顾：
- 香港服务器直连 OpenAI 被 Cloudflare 按地区拦截 → 挂美国 SOCKS 代理出海解决
- 本地 v2rayN 会劫持到服务器 IP 的连接 → 需加直连规则
- systemd 系统级服务 + `Environment=HOME=/root` + auth-dir 绝对路径 → 解决启动崩溃

---

## 十四、账号状态与用量监控

EasyCLI 桌面客户端的 Authentication Files 页**只列账号文件（名字/大小/时间），不显示状态和用量**。看账号能不能用、用了多少，用下面的方式。

### 首选：官方内置 Web 管理面板（功能最全）

CPA 内置官方管理面板 [Cli-Proxy-API-Management-Center](https://github.com/router-for-me/Cli-Proxy-API-Management-Center)，浏览器直接打开：

```
https://<你的域名>/management.html
```

首次打开填服务地址 + 管理密钥（secret-key），即可看到：**账号有效性判断、配额、用量统计、日志可视化、配置修改、OAuth 登录、批量删除账号**。

- 面板由服务器自动从 GitHub 下载（配置 `panel-github-repository` 指定来源）
- 打开报 404：检查 `remote-management.disable-control-panel` 是否被设为 `true`（设 true 会禁用），改回 false

### 备选：命令行 / 脚本查

```bash
# 看每个账号的状态(能否用)+ 成功/失败次数
curl -H "Authorization: Bearer <secret-key>" https://<域名>/v0/management/auth-files

# 看 token 级用量(需先开启统计)
curl -X PUT https://<域名>/v0/management/usage-statistics-enabled -H "Authorization: Bearer <secret-key>" -H "Content-Type: application/json" -d '{"value":true}'
curl "https://<域名>/v0/management/usage-queue?count=20" -H "Authorization: Bearer <secret-key>"
```

`/auth-files` 关键字段：`status`（ready=可用）、`status_message`、`success`/`failed`、`disabled`。
`/usage-queue` 是**读一次清一条**的队列，适合定时拉取入库，不是持久报表。

### 最准的判断：直接发测试请求

```bash
curl -X POST https://<域名>/v1/responses -H "Authorization: Bearer <api-key>" -H "Content-Type: application/json" -d '{"model":"gpt-5.5","input":"ping"}'
```

返回正常回复=号能用；报错（insufficient_quota / 401 / 地区拦截）=号有问题。

### 社区第三方监控工具

- **codex-quota-monitor**（`pip install codex-quota-monitor`，`cqm` 命令，专盯 Codex 配额，独立 Web UI）
- **cliproxyapi-dashboard**（GitHub: itsmylife44）

---

## 十五、对外接口清单

CPA 同时提供 **OpenAI / Gemini / Claude 三种格式**接口，均用 `api-keys`（`sk-...`）鉴权。

**在线接口文档（可浏览器直接看）**：https://router-for-me-cliproxyapi.mintlify.app/api/overview

### OpenAI 格式（前缀 `/v1`）

| 端点 | 用途 |
|---|---|
| `POST /v1/chat/completions` | 对话（最通用） |
| `POST /v1/completions` | 文本补全 |
| `POST /v1/responses`、`/v1/responses/compact` | Responses API（Codex 用） |
| `GET /v1/responses` | Responses 的 WebSocket |
| `POST /v1/messages`、`/v1/messages/count_tokens` | Claude 格式对话 |
| `POST /v1/images/generations` | 文生图 |
| `POST /v1/images/edits` | 图片编辑 |
| `GET /v1/models` | 列出可用模型 |

> 图片端点由配置 `disable-image-generation` 控制。

### Gemini 原生格式（前缀 `/v1beta`）

| 端点 | 用途 |
|---|---|
| `POST /v1beta/models/{model}:generateContent` | 对话（非流式） |
| `POST /v1beta/models/{model}:streamGenerateContent` | 对话（流式） |
| `POST /v1beta/models/{model}:countTokens` | 计算 token |
| `GET /v1beta/models`、`/v1beta/models/{model}` | 模型列表/详情 |

### OAuth 回调（登录流程自动用，无需手动调）

`/anthropic/callback`、`/codex/callback`、`/antigravity/callback`（见 `internal/api/server_routes.go`）

这三条注册在主端口 `8317` 上，供管理面板发起的登录流程接收 provider 重定向。另有 `POST/GET /v0/management/oauth-callback` 用于面板侧提交回调 URL。

### 管理接口（前缀 `/v0/management`，用 secret-key）

`/config`、`/auth-files`、`/usage-queue`、`/api-keys` 等 + 控制面板 `GET /management.html`

### 说明

- 三种格式指向同一批底层账号，客户端习惯哪种格式就用哪种
- 具体能用哪些模型取决于登录了哪些账号，实时查询：`GET /v1/models`
- 响应支持 JSON、SSE 流式、WebSocket 三种
- 上游返回 403、408、500、502、503、504 时自动重试，次数由 `request-retry` 控制（默认 3）；另有 `max-retry-credentials`（换几个凭据重试，默认 0）和 `max-retry-interval`（等待冷却凭据的上限秒数，默认 30）。三项的说明见 `config.example.yaml` 第 144-152 行
- CPA 服务本身不带 Swagger 交互式 UI，接口文档看上面的在线文档站

---

## 十六、域名 + 宝塔反向代理 + HTTPS（推荐，替代裸 IP:8317）（实践五）

用域名走标准 HTTPS 访问，比 `http://IP:8317` 更安全、更专业，还能隐藏 8317 端口。

### 1. 加 A 记录
域名 DNS 后台加一条 A 记录：`域名 → 服务器IP`。验证：`nslookup 域名` 能解析到该 IP。

### 2. 宝塔新建站点
宝塔 → 网站 → 添加站点 → 域名填你的域名，纯静态（不要数据库/PHP）。

### 3. 配置反向代理
站点设置 → 反向代理 → 添加：
- 目标 URL：`http://127.0.0.1:8317`
- 发送域名：`$host`

### 4. 确认 WebSocket 支持（Codex 等需要）
宝塔反代默认会带 WebSocket 配置，反代 location 里应包含：
```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_read_timeout 600s;
```
`$connection_upgrade` 需在全局有 `map` 定义（宝塔开 WebSocket 支持时自动加）。改完用 `nginx -t` 验证：
- `successful` = 配置 OK
- 报 `unknown "connection_upgrade" variable` = map 没定义，需在 http 段补：
  ```nginx
  map $http_upgrade $connection_upgrade { default upgrade; '' close; }
  ```

### 5. 申请免费 HTTPS
站点设置 → SSL → Let's Encrypt → 勾选域名 → 申请 → 开启「强制 HTTPS」。
（申请失败多半是 80 端口没放行或 DNS 没生效）

### 6. CPA 改为只监听本地
既然由宝塔反代，CPA 不必再暴露公网：
```yaml
host: "127.0.0.1"
port: 8317
```
`systemctl restart cliproxyapi`

### 7. 收尾
- 删掉 8317 的公网放行（云安全组 + 宝塔），只留 443、80（续签用）、22
- 客户端全改用域名：EasyCLI 填 `https://域名`、Codex `base_url` 填 `https://域名/v1`

### 排查
- 反代后 502：CPA 没起来或没监听 127.0.0.1:8317
- Codex 连不上/流式断：检查第 4 步 WebSocket 配置

---

## 十七、Docker 部署方式（替代 systemd 方案）

适合生产/长期运行，配置和凭证挂在宿主机 volume，升级不丢数据。Docker 方式无 systemd 的 `$HOME`/`--user` 那些坑。

Docker 编排文件统一放在 `deploy/dev/`，完整说明见 [deploy/dev/README_CN.md](deploy/dev/README_CN.md)。

### 方式一：docker run（单容器，最快上手）

```bash
mkdir -p /root/cliproxy/auth-dir
# 先准备好 /root/cliproxy/config.yaml，且 auth-dir 写绝对路径 /root/.cli-proxy-api

docker run -d --name cliproxyapi --restart unless-stopped \
  -p 8317:8317 \
  -v /root/cliproxy/config.yaml:/CLIProxyAPI/config.yaml \
  -v /root/cliproxy/auth-dir:/root/.cli-proxy-api \
  eceasy/cli-proxy-api:latest
```

改配置后 `docker restart cliproxyapi`（配置热重载生效时无需重启）。

### 方式二：docker compose（推荐，仓库自带编排）

```bash
cd /root/CLIProxyAPI
cp config.example.yaml config.yaml     # ← 必做，见下方警告

docker compose \
  -f deploy/dev/docker-compose.yml \
  --project-directory . \
  up -d
```

或用封装脚本（已内置 `--project-directory`）：

```bash
./deploy/dev/build.sh      # Linux/macOS
.\deploy\dev\build.ps1     # Windows
```

### ⚠️ 两个必踩的坑

**1. `config.yaml` 必须先创建成文件。** volume 挂载的宿主机路径不存在时，Docker 会自动创建一个**同名空目录**，容器读配置失败、崩溃重启循环。修复要先 `rm -rf config.yaml` 再建文件，不如一开始就 `cp`。

**2. 手动跑 compose 必须带 `--project-directory`。** compose 文件在 `deploy/dev/` 下，但 volume 相对路径是按 **project 目录**解析的，不是按 compose 文件所在目录。漏了这个参数，会在 `deploy/dev/` 下另生成一套 `config.yaml`/`auths/`，实测结果：

| 命令 | volume 实际指向 |
|---|---|
| `-f deploy/dev/docker-compose.yml --project-directory .` | `<repo>/config.yaml` ✅ |
| `cd deploy/dev && docker compose -f docker-compose.yml` | `<repo>/deploy/dev/config.yaml` ❌ |

启动前先验证：

```bash
docker compose -f deploy/dev/docker-compose.yml --project-directory . config
```

### 端口精简

**8317** 是唯一始终必需的端口（API + 管理接口）。OAuth 回调端口有三个，各归各家、不能互相替代：`54545` 给 Anthropic/Claude、`1455` 给 Codex、`51121` 给 Antigravity。只在通过管理面板登录对应厂商时需要从浏览器所在机器可达，登录完成后可以关闭。只放行 `1455` 就登不了 Claude 和 Antigravity，且失败表现是等约 5 分钟超时而不是立即报错。

`8085` 和 `11451` 在代码中没有对应监听，属历史遗留映射，编排文件里已默认注释。端口与用途的完整对照见 [`deploy/dev/README_CN.md`](deploy/dev/README_CN.md) 第六节。

---

## 十八、EasyCLI 使用要点

### Local vs Remote
- **Local**：在本机启动并运行一个 CPA 服务，适合 Windows 自用
- **Remote**：不跑服务，作为远程控制台连接已部署的 CPA（本方案用这个）

### 连接
Remote → 地址填 `http://IP:8317` 或反代后的 `https://域名` → 管理密钥填 secret-key → Connect。

### 切换连接地址（如 IP 换成域名）
断开当前连接重连即可（找断开按钮，或直接关掉 EasyCLI 重开回到 Local/Remote 选择界面），用新地址重连。**切换地址不影响已登录的 AI 账号**（凭证在服务器的 auth-dir，与连接方式无关）。

### 注意
- Basic Setting 页 Secret Key 框是空的，点 Apply 不会清空 secret-key（API 不允许改该项）
- Proxy URL 等其他项在此页填 → Apply 会热重载，无需重启


## 十九、 Gemini 报 "User location is not supported" 排查记录

### 现象

调用 Gemini / Antigravity 模型（如 `gemini-3.5-flash-low`）报错：

```
400 FAILED_PRECONDITION
User location is not supported for the API use.
```

同一账号下 Claude、Codex 正常，**只有 Gemini 失败**。

### 本次排查结论

本次环境确认 Gemini（Cloud AI Companion / CloudCode）后端进行了**出口 IP 地区校验**。
请求通过代理后，官方 Antigravity IDE 使用同一出口仍然复现，因此问题不属于 CLIProxyAPI 独有故障。

当前出口是某机房 ASN 的 IP，虽然 ipinfo 显示 country=US，仍被 Google 判为「位置不支持」。结合本次现象，**该出口 IP 未被 Gemini 地区校验接受是最高概率原因**，但现有证据不能推导出“所有机房 IP 都不受支持”，也未完全排除账号地区、Google IP 定位库和模型端点可用区域等因素。

### 排查过程（关键结论）

1. Codex、Claude 请求成功，只能证明它们当前使用的出口可用，**不能据此认定 Gemini 也在使用同一个全局代理**。
2. 先检查目标 Gemini 账号在 `auth-dir`（本手册为 `/root/.cli-proxy-api/`）中的凭据 JSON：
   - 存在非空 `proxy_url`：实际使用账号级代理，修改 `config.yaml` 的全局 `proxy-url` 不会影响该账号。
   - 没有 `proxy_url` 或值为空：实际回退使用全局 `proxy-url`；全局也为空时才走服务器直连。
3. 只有确认目标账号使用全局代理后，把全局代理临时改成 `socks5://127.0.0.1:1`，请求出现 `socks connect ... connection refused`，才能证明该请求确实经过全局代理。若账号存在 `proxy_url`，应在账号级配置上做等价验证。
4. 官方 Antigravity IDE 使用同一出口时，Claude 能用、Gemini 报同样的 `User location is not supported`
   → 证明问题发生在 Google Gemini 的地区校验链路，不是 CLIProxyAPI 独有问题。
5. 当前出口是某机房 ASN 的 IP，ipinfo 显示 US 但仍被拦
   → 支持“当前出口 IP 未被 Gemini 接受”的判断，但不能泛化到所有机房 IP。

### 解决办法

先按第六节的代理优先级确认要修改哪一级：

```text
账号/凭据级 proxy_url（最高） > config.yaml 全局 proxy-url > 服务器直连
```

账号级 `proxy_url` 配置示例（用占位符，切勿写入真实凭据）：

```text
"proxy_url": "socks5://<user>:<pass>@<proxy-host>:<port>",
```

- **只替换目标 Gemini 账号的出口**：修改 `/root/.cli-proxy-api/<对应账号>.json` 顶层的 `"proxy_url"`，设置为已验证的美国住宅代理。该配置会覆盖全局代理。
- **让所有未单独配置代理的账号共用新出口**：修改 `config.yaml` 的全局 `proxy-url`。如果目标账号已有非空 `proxy_url`，必须先删除该字段或将其置空，否则新的全局代理对该账号不生效。
- **恢复服务器直连**：账号级 `proxy_url` 和全局 `proxy-url` 都必须删除或置空；只清理其中一级不一定会直连。

修改后分别在官方 Antigravity IDE 和 CLIProxyAPI 中重试 Gemini；两端都成功后，才能确认本次故障由原出口 IP 引起。如果仍失败，继续检查账号地区、Google 对出口 IP 的定位结果，以及目标模型端点的可用区域。编辑凭据 JSON 时不要输出或改动同文件中的 access token、refresh token。

### 备注

- 排查中账号授权文件里的 refresh_token 曾外泄，建议到该 Google 账号
  [第三方授权页](https://myaccount.google.com/permissions) 撤销并重新登录换新凭证。

---

## 参考链接

- 官方文档：https://help.router-for.me/cn/introduction/quick-start.html
- 主程序仓库：https://github.com/router-for-me/CLIProxyAPI
- EasyCLI 桌面客户端：https://github.com/router-for-me/EasyCLI
- 管理 API 文档：https://help.router-for.me/cn/management/api.html
- Codex 接入文档：https://help.router-for.me/cn/agent-client/codex.html
- 在线 API 文档：https://router-for-me-cliproxyapi.mintlify.app/api/overview
- 官方 Web 管理面板：https://github.com/router-for-me/Cli-Proxy-API-Management-Center
- 安装脚本（已审查，无后门）：https://github.com/router-for-me/cliproxyapi-installer
