# caddy — Multica 反向代理

以独立容器（`caddy:2-alpine`）为 `../multica` 提供反向代理，
是 Multica 局域网访问的**必要组件**。

与 `multica/` 在目录结构上平级：两者是各自独立的 Compose 项目，可分别启停。

## 为什么需要它

Next.js 的 rewrites 会把 `/v1`、`/api`、`/auth`、`/uploads` 转发给后端，
所以**普通 HTTP 请求在局域网下开箱即用**。

但 rewrites 只转发 HTTP 请求，**无法承载 WebSocket 的 `Upgrade` 握手**。
结果是：浏览器从 `http://192.168.50.248:3000` 打开应用时，页面能加载、能刷新，
但实时功能（聊天流式输出、issue 实时更新、通知）静默失效，
console 持续打印 `disconnected, reconnecting in 3s`。

Caddy 负责终止 `/ws` 的升级握手并转发给后端，解决这个问题。

## 架构

```
浏览器 http://192.168.50.248:3000
        │
        ▼
   ┌─────────┐
   │  caddy  │
   └────┬────┘
        │ /ws  → multica-backend:8080   （flush_interval -1）
        │ 其余 → multica-frontend:3000
        │
   Docker 网络 multica-net（external，由 ../multica 创建）
```

采用**同源单布局**：前端与后端共用一个 hostname/port。
浏览器因此始终在页面自身的 origin 上调用 `/api` 与 `/ws`，
不会产生跨主机 Cookie 或 CSRF 问题，会话 Cookie 保持 host-only。
这是上游推荐的布局。

## 文件

| 文件 | 说明 |
|:---|:---|
| `Caddyfile` | 反代配置 |
| `docker-compose.yml` | caddy 服务定义（接入 `multica-net` 外部网络） |
| `deploy.sh` | 校验配置 → 启动 → 冒烟测试 |
| `stop.sh` | 停止代理 |

## 快速开始

```bash
# 前置：Multica 栈必须已在运行（它创建 multica-net 网络）
bash nodes/mac-mini-m4/multica/deploy.sh

# 启动代理
bash nodes/mac-mini-m4/caddy/deploy.sh

# 停止
bash nodes/mac-mini-m4/caddy/stop.sh
```

`deploy.sh` 会做三件事，任一失败即退出：

1. **检查 `multica-net` 存在** —— 不存在则提示先启动 Multica 栈。
2. **`caddy validate` 校验 Caddyfile** —— 语法错误在这里以可读信息报出，
   而不是变成只有 `docker logs caddy` 才看得见的重启循环。
3. **冒烟测试** —— 通过代理请求 `/health`，确认确实转发到了后端。

## 配置要点

### 网络

caddy 以 `external: true` 接入 `multica-net`，因此可以按容器名
（`multica-backend`、`multica-frontend`）反代 —— 这也是
`../multica/docker-compose.yml` 中显式设置 `container_name` 的原因：
Caddy 不能依赖 Compose 自动生成的 `<project>-<service>-<n>` 命名。

两个栈分别 `docker compose down` 时互不影响：`stop.sh` 不会删除
`multica-net`（它属于 Multica 栈所有）。

### 端口

caddy 是**本机唯一绑定 `0.0.0.0` 的容器**：`3000:3000`。

Docker Desktop 会绕过 macOS 应用防火墙，端口一旦 publish 到 `0.0.0.0`
整个局域网即可访问，与系统防火墙设置无关。因此只暴露反代这一个入口，
后端（`127.0.0.1:8080`）与前端（`127.0.0.1:3001`）都留在宿主环回。

### Caddyfile 中三个容易写错的点

**站点地址用裸端口 `:3000`，不要写 `http://192.168.50.248:3000`。**
写 IP 字面量会让 Caddy 编译出一个绑定该 Host 头的 `host` 匹配器，
于是以 `localhost:3000` 或其他 Host 到达的请求**不匹配任何路由**，
落到默认的空 200 响应 —— 现象是"代理起来了、配置校验通过、但所有请求都返回空 200"，
极具迷惑性。裸端口服务所有 Host 与所有网卡，这正是单机局域网入口需要的，
同时也把 IP 从这个文件里移除，机器地址变化时无需再改它。

**`path /ws /ws/*` 而非 `/ws*`。** Caddy 的 `*` 没有路径段边界，
`/ws*` 会连带匹配 `/ws-foo`，而这是个合法的 workspace slug
（只有精确的 `ws` 被保留）。反过来，裸 `handle /ws` 是精确匹配，
会漏掉未来可能的 `/ws/...` 变体。列出两个才既覆盖真实情况又不过度匹配。

**`flush_interval -1`。** 禁用响应缓冲，让帧到达即转发。
不加的话帧会卡在 Caddy 默认的 flush 窗口后面 ——
表现为评论延迟出现、输入中指示器消失，或"评论要刷新页面才看得到"。

### 必须清空容器内的 proxy 环境变量

`docker-compose.yml` 里显式把 `HTTP_PROXY` / `HTTPS_PROXY` / `http_proxy` /
`https_proxy` 置空，并把 `NO_PROXY` / `no_proxy` 设为 `*`。这不是可选项。

Docker Desktop 会把 **macOS 系统代理**注入到每个容器中
（本机是 `host.docker.internal:7897`）。Caddy **默认会为自身出站连接使用
`HTTP_PROXY`**，于是每一次 `reverse_proxy` 拨号都被送到宿主代理，
而宿主代理无法解析 `multica-backend` 这类 Docker 内部主机名，直接回 `502`。
典型症状同样是"容器正常启动、配置校验通过、但每个请求都 502"。

清空是安全的：本代理只与 `multica-net` 上的容器通信，不需要任何出站访问，
且在 HTTP-only 模式下 Caddy 不会去申请 ACME 证书。

> 同类陷阱会影响任何在容器内发起 HTTP 请求的测试命令。
> 用 curl/wget 验证时记得加 `--noproxy '*'`，否则会得到与真实故障无关的 502。

### 明文 HTTP

Caddyfile 中显式写了 `http://` scheme。Caddy 默认会尝试自动申请 TLS 证书，
而对局域网裸 IP 这不可能成功，失败会阻塞站点。显式写 scheme 可抑制该行为。

## 排错

| 现象 | 处理 |
|:---|:---|
| 每个请求都返回**空 200**（`Content-Length: 0`，无上游响应头） | 站点地址被写成了 IP 字面量，编译出 `host` 匹配器，请求不匹配任何路由。改成裸端口 `:3000`，然后 `docker compose up -d --force-recreate` —— 只改挂载的 Caddyfile 不会让 `up -d` 重建容器，旧配置会一直生效 |
| 每个请求都 **502** | ① 上游容器没在跑（`docker ps`）；② 容器内 proxy 环境变量污染，见下文「必须清空容器内的 proxy 环境变量」。先 `docker compose exec caddy env \| grep -i proxy` 确认 |
| `caddy:2-alpine` 拉取失败 / 超时 / `EOF` | Docker Hub 在本网络不可达。先配置镜像并重启 Docker Desktop：`bash ../config/set-docker-mirror.sh` |
| `ERROR: Docker network 'multica-net' not found` | 先启动 Multica 栈：`bash ../multica/deploy.sh` |
| Caddyfile 校验失败 | `deploy.sh` 会打印 `caddy validate` 的完整输出。改动后用同样命令单独验证：`docker run --rm -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` |
| 改了 Caddyfile 但不生效 | `docker compose up -d` 认为容器无变化，不会重载。用 `docker compose up -d --force-recreate`，或直接 `docker compose restart caddy` |
| 页面正常但实时功能失效 | 这是**后端 Origin 白名单**问题而非反代问题：`../multica/.env` 的 `CORS_ALLOWED_ORIGINS` 必须等于浏览器实际 origin。后端日志关键字 `websocket: request origin not allowed by Upgrader.CheckOrigin` |
| 想看访问日志 | `docker compose logs -f caddy` |

## 验证

局域网内另一台机器打开 `http://192.168.50.248:3000`，
DevTools → Network 过滤 `ws`：`/ws` 应为 **`101 Switching Protocols`**。
若持续重连则是上述 Origin 白名单问题。

命令行验证反代是否确实转发到上游（注意 `--noproxy '*'`，原因见上）：

```bash
# 必须返回后端的 JSON 与 CSP 头，而不是空 200
curl -s --noproxy '*' -i http://192.168.50.248:3000/health

# 前端 HTML
curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{content_type} %{size_download}\n' \
  http://192.168.50.248:3000/

# 前端 rewrite 到后端（返回配置 JSON）
curl -s --noproxy '*' http://192.168.50.248:3000/api/config
```

判定标准：`/health` 必须带有后端特有的 `Content-Security-Policy` 与
`X-Middleware-Rewrite: http://backend:8080/health` 响应头。
**空的 `Content-Length: 0` + 200 表示请求没有匹配到任何路由**，
见排错表第一行。

## 维护记录

| 日期 | 事项 | 说明 |
|:---|:---|:---|
| 2026-05-24 | 初始部署 | 以 `caddy:2-alpine` 容器部署；接入 `multica-net` 外部网络；同源单布局转发 `/ws` 与其余流量 |