# Docker 部署配置模板

本目录包含服务器部署所需的配置文件模板。

## 文件说明

| 文件 | 用途 | 目标位置 |
|------|------|----------|
| `docker-compose.example.yml` | 容器编排配置 | 服务器：`/root/cliproxyapi-docker/docker-compose.yml` |
| `.env.example` | 环境变量（镜像版本、端口等） | 服务器：`/root/cliproxyapi-docker/.env` |
| `config.example.yaml` | 应用配置（API 密钥、提供商等） | 服务器：`/root/cliproxyapi-docker/config.yaml` |
| `nginx.example.conf` | 反向代理配置（HTTPS + 域名） | 服务器：`/etc/nginx/conf.d/cliproxyapi.conf` |

## 使用方法

### 方式 1：通过 deploy.sh 自动部署（推荐）

`deploy.sh` 脚本会自动生成这些文件，你不需要手动复制模板：

```bash
# 本地机器构建并推送镜像
cd deploy/docker
.\build-push.ps1

# 复制 deploy.sh 到服务器
scp deploy/docker/deploy.sh root@your-server:/root/

# SSH 登录服务器执行部署
ssh root@your-server
chmod +x /root/deploy.sh

# 不带参数 = 私有镜像 + :latest（都是内置默认值）
/root/deploy.sh

# 需要锁定版本时才显式指定
# /root/deploy.sh --version v7.2.118
```

脚本会自动创建 `/root/cliproxyapi-docker/` 目录并生成配置文件。

### 方式 2：手动复制模板文件

如果你想手动准备配置文件：

```bash
# 1. 在服务器创建部署目录
ssh root@your-server
mkdir -p /root/cliproxyapi-docker/{auths,logs,plugins}
exit

# 2. 从本地复制模板文件到服务器（本地机器执行）
scp deploy/docker/templates/docker-compose.example.yml root@your-server:/root/cliproxyapi-docker/docker-compose.yml
scp deploy/docker/templates/.env.example root@your-server:/root/cliproxyapi-docker/.env
scp deploy/docker/templates/config.example.yaml root@your-server:/root/cliproxyapi-docker/config.yaml

# 3. SSH 登录服务器并编辑配置
ssh root@your-server
cd /root/cliproxyapi-docker

# 编辑 .env 设置镜像版本
nano .env

# 编辑 config.yaml 修改 secret-key 和 api-keys
nano config.yaml

# 4. 启动容器
docker compose pull
docker compose up -d
```

## 配置说明

### docker-compose.yml

- 不要修改容器内部端口（固定 8317）
- OAuth 回调端口默认注释，按需取消注释
- 卷挂载路径相对于 compose 文件位置

### .env

必须修改的字段：

```bash
CLI_PROXY_VERSION=latest    # 默认跟随最新构建；要锁版本改成具体 tag
CLI_PROXY_BIND=127.0.0.1    # 生产环境保持 127.0.0.1
CLI_PROXY_PORT=8317         # 宿主机暴露端口
```

### config.yaml

必须修改的字段：

```yaml
remote-management:
  secret-key: "your-secure-secret-key-here"  # 改为强密码

api-keys:
  - "sk-your-api-key-1"  # 改为实际的 API 密钥
  - "sk-your-api-key-2"
```

关键配置约束（Docker 场景）：

```yaml
# 正确：绑定容器内所有接口
host: ""

# 错误：绑定容器内环回接口会导致端口映射失效
# host: "127.0.0.1"

# 正确：匹配卷挂载目标
auth-dir: "/root/.cli-proxy-api"

# 错误：不匹配卷挂载会导致凭据丢失
# auth-dir: "~/.cli-proxy-api"
```

## 配置 Nginx 反向代理（可选）

如果需要通过域名和 HTTPS 访问：

```bash
# 1. 复制 Nginx 配置模板到服务器
scp deploy/docker/templates/nginx.example.conf root@your-server:/etc/nginx/conf.d/cliproxyapi.conf

# 2. SSH 登录服务器编辑配置
ssh root@your-server
nano /etc/nginx/conf.d/cliproxyapi.conf
# 必须修改的字段：
# - server_name: 改为你的域名
# - ssl_certificate: 改为你的证书路径
# - ssl_certificate_key: 改为你的私钥路径

# 3. 测试并重载 Nginx
nginx -t && nginx -s reload
```
配置后可通过 `https://api.yourdomain.com/v1/models` 访问。

## 验证部署

```bash
# 检查容器状态
docker ps

# 查看日志
docker logs cli-proxy-api

# 测试 API
curl -H "Authorization: Bearer sk-your-api-key-1" \
  http://127.0.0.1:8317/v1/models
```

## 更多信息

- 完整部署教程：[../README_CN.md](../README_CN.md)
- 部署流程图：[../deploy-flow.md](../deploy-flow.md)
- 完整配置参考：[../../../config.example.yaml](../../../config.example.yaml)
