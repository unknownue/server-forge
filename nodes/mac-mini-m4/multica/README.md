# multica — 自托管 AI Agent 工作区

在 `mac-mini-m4` 上以 Docker Compose 运行 Multica 服务栈（PostgreSQL + backend + frontend），
供局域网访问。

Multica 是一个把 AI 编码 agent 当作团队成员的工作区：给 agent 分配 issue，它自行领取、
在受控的 runtime 上执行、汇报进度并交回评审。服务端只负责编排，**不附带模型** ——
它驱动的是你本机已安装并登录的 agent CLI。

> 上游文档：[SELF_HOSTING.md](../../../submodules/multica/SELF_HOSTING.md)、
> [SELF_HOSTING_ADVANCED.md](../../../submodules/multica/SELF_HOSTING_ADVANCED.md)。
> 本目录的文件是从上游派生的**独立副本**，不引用 submodule 路径，
> 因此 `submodules/multica` 不存在时本部署依然完整可用。

## 架构

```
局域网浏览器
     │  http://192.168.50.248:3000
     ▼
┌─────────────────────────────────────────────┐
│ caddy（../caddy）  ← 对外唯一入口             │
│   /ws       → multica-backend:8080（WS 升级）│
│   其余       → multica-frontend:3000         │
└─────────────────────────────────────────────┘
     │  Docker 网络 multica-net
     ├── multica-frontend   Next.js 16
     ├── multica-backend    Go（REST + WebSocket）
     └── multica-postgres   PostgreSQL 17（pgvector）

宿主机（macOS 原生，不在 Docker 内）
     └── multica daemon ──→ 调用本机 claude / dsh 等 agent CLI
```

## 端口分配

| 服务 | 容器内 | 宿主发布 | 说明 |
|:---|:---|:---|:---|
| caddy | 3000 | **`0.0.0.0:3000`** | 对外唯一入口 |
| multica-frontend | 3000 | `127.0.0.1:3001` | 让出 3000 给 caddy |
| multica-backend | 8080 | `127.0.0.1:8080` | 供本机 CLI 与排错直连 |
| multica-postgres | 5432 | **不发布** | 仅容器网络内可达 |

> **为什么只有 caddy 绑 `0.0.0.0`**：Docker Desktop 会绕过 macOS 应用防火墙，
> 只要端口被 publish 到 `0.0.0.0`，整个局域网就能访问，与系统防火墙设置无关。
> 因此只暴露反代这一个入口，后端与数据库保持在宿主环回。
> 上游 compose 默认把 postgres publish 到 `127.0.0.1:5432`，本节点删除了该映射 ——
> 没有宿主进程需要直连数据库，用 `docker compose exec postgres psql` 即可。

## 文件

| 文件 | 说明 |
|:---|:---|
| `docker-compose.yml` | 服务栈定义（从上游派生，改动处标注 `# [mac-mini-m4]`） |
| `.env.example` | 配置模板（已入库，无真实密钥） |
| `.env` | 真实配置与密钥（**不入库**，由 `deploy.sh` 生成，权限 600） |
| `deploy.sh` | 一键部署：生成 `.env` → 拉镜像 → 启动 → 健康检查 |
| `stop.sh` | 停止服务栈（保留数据卷） |

## 快速开始

```bash
# 0. 先配置 Docker Hub 镜像加速（本机直连 Docker Hub 不可达，见下）
bash nodes/mac-mini-m4/config/set-docker-mirror.sh
osascript -e 'quit app "Docker"' && sleep 3 && open -a Docker

# 1. 启动服务栈
bash nodes/mac-mini-m4/multica/deploy.sh

# 2. 启动反向代理（局域网访问必需）
bash nodes/mac-mini-m4/caddy/deploy.sh

# 3. 验证
curl -s http://localhost:8080/readyz
```

启动后浏览器打开 **http://192.168.50.248:3000**（本机可用 http://localhost:3000）。

停止：

```bash
bash nodes/mac-mini-m4/caddy/stop.sh
bash nodes/mac-mini-m4/multica/stop.sh
```

## 镜像拉取

上游镜像发布在 GHCR（`ghcr.io/multica-ai/multica-{backend,web}`），
两者均提供 `linux/arm64`，在 M4 上**原生运行，无需构建**。

本机的网络环境有两点需要注意：

1. **Docker Hub 直连不可达。** 实测 `registry-1.docker.io` 的 token 端点返回 `EOF`，
   任何 Docker Hub 拉取都会挂起或失败。这影响 `caddy:2-alpine` 以及未来的其他镜像，
   由 `../config/set-docker-mirror.sh` 写入 `~/.docker/daemon.json` 解决。
2. **registry mirror 不覆盖 ghcr.io。** `registry-mirrors` 只代理 Docker Hub。
   因此 `deploy.sh` 对 Multica 镜像采用**前缀重打 tag**：
   先从 `<mirror>/ghcr.io/multica-ai/<img>:<tag>` 拉取，再重新打上
   `ghcr.io/multica-ai/<img>:<tag>` 标签。Compose 引用的是后者，命中本地镜像后不再联网。

若 mirror 不代理 GHCR，`deploy.sh` 自动回退直连 `ghcr.io`；两者都失败才报错，
并给出三条出路（换 mirror、清空 `GHCR_MIRROR`、`--build` 从源码构建）。**不会静默降级。**

### 固定版本

`.env` 中 `MULTICA_IMAGE_TAG=latest`。要固定版本，改为具体 release（如 `v0.4.10`）。
查询可用 tag：

```bash
curl -s "https://ghcr.io/token?scope=repository:multica-ai/multica-backend:pull&service=ghcr.io" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' \
  | xargs -I{} curl -s -H "Authorization: Bearer {}" \
    "https://ghcr.io/v2/multica-ai/multica-backend/tags/list"
```

### 从源码构建（兜底）

仅当镜像拉取全部失败时使用，需要 `submodules/multica` 已 checkout，
且耗时较长（Go 1.26 + pnpm 构建）：

```bash
bash nodes/mac-mini-m4/multica/deploy.sh --build
```

## 为什么必须有反向代理

Next.js 的 rewrites 会把 `/v1`、`/api`、`/auth`、`/uploads` 转发给后端，
所以**普通 HTTP 在局域网下开箱即用**。但 rewrites 只转发 HTTP 请求，
**无法承载 WebSocket 的 `Upgrade` 握手**。

后果是：从 `http://192.168.50.248:3000` 打开应用时，页面能加载、能刷新，
但实时功能（聊天流式输出、issue 实时更新、通知）**静默失效** ——
浏览器 console 会持续打印 `disconnected, reconnecting in 3s`。

因此 `../caddy/` 是局域网访问的**必要组件**，不是可选项。详见其 README。

## 配置要点

`.env` 中几个容易出错的项：

| 变量 | 值 | 说明 |
|:---|:---|:---|
| `FRONTEND_ORIGIN` | `http://192.168.50.248:3000` | 浏览器实际使用的 origin |
| `CORS_ALLOWED_ORIGINS` | `http://192.168.50.248:3000` | **WebSocket Origin 白名单的独立开关** |
| `MULTICA_TRUSTED_PROXIES` | `172.16.0.0/12` | caddy 在容器网络内，源 IP 是 Docker 网段 |
| `APP_ENV` | `production` | 无固定验证码；`MULTICA_DEV_VERIFICATION_CODE` 被忽略 |
| `DO_NOT_TRACK` | `1` | 关闭上游第一方遥测 |

`CORS_ALLOWED_ORIGINS` 值得单独强调：后端的 WebSocket `Origin` 校验默认**只允许 localhost**。
不设置它时，`/ws` 升级会被拒绝并返回 `403`，而后端日志里是
`websocket: request origin not allowed by Upgrader.CheckOrigin`，
同时**普通 HTTP 依旧正常** —— 所以现象具有迷惑性，页面看起来完全没问题。

> **IP 变更清单**：`192.168.50.248` 目前由 Wi-Fi DHCP 分配。若改为静态 IP 或地址变化，
> 只需修改 `.env` 的 `FRONTEND_ORIGIN` 与 `CORS_ALLOWED_ORIGINS`（两处），
> 然后重启后端：`docker compose up -d --force-recreate backend`。
> `../caddy/Caddyfile` 使用裸端口 `:3000`，**不含 IP**，因此无需改动。

## 首次登录

`APP_ENV=production` 下没有固定验证码。三种方式：

**推荐 —— 配置邮件。** 在 `.env` 中填 `SMTP_HOST`（或 `RESEND_API_KEY`），
然后 `docker compose up -d backend` 重启后端。验证码会真实发送到邮箱。
`SMTP_HOST` 优先于 `RESEND_API_KEY`。

**未配置邮件 —— 从日志读取：**

```bash
docker logs multica-backend 2>&1 | grep "Verification code"
```

**不推荐 —— 固定验证码。** `MULTICA_DEV_VERIFICATION_CODE=888888` 仅作一次性测试用。
本部署局域网可达，固定码意味着**任何知道邮箱地址的人都能登录**。
若临时启用，测试后必须移除该行并重启后端。

## 拓扑：本机只做服务端

**这台机器不跑 agent daemon。** 它是 Multica 的**控制平面**：Web UI、API、数据库、调度。
所有 agent 执行发生在局域网内的开发机上。

```
┌──────────────────────────┐        ┌────────────────────────────────┐
│ mac-mini-m4（本机）       │        │ 开发机（局域网，每台一个）      │
│  控制平面                 │  LAN   │  multica daemon                │
│                          │◀───────│   └── dsh                      │
│  caddy :3000             │        │        （容器或原生，由该机决定）│
│   ├ /api/daemon/* → backend       │                                │
│   ├ /ws           → backend       │        │                       │
│   └ 其余          → frontend      │        ▼                       │
│                          │        │  本地模型端点（GPU 机器）       │
│  multica-backend :8080   │        │                                │
│  multica-postgres        │        │                                │
└──────────────────────────┘        └────────────────────────────────┘
```

**本机不装 dsh，也不配任何模型。** Multica 服务端不调用模型：
`.env.example` 里的 `MULTICA_LLM_*` 层只用于聊天自动起标题和生成追问建议，
本部署**刻意留空**（留空是官方支持的配置，此时它发出零个上游请求）。
真正调用模型的是开发机上的 dsh。

daemon 的安装方式由那台机器自己决定 —— 容器化或原生安装都可以，
本机只需要保证网络可达（见下节两处配置）。账户对接走
`multica setup self-host --server-url http://192.168.50.248:3000`，
或 `multica login --token mul_...`（无浏览器环境）。

### 服务端为此做的两处配置

**1. `MULTICA_DAEMON_SERVER_URL`（必须显式设置）**

后端的推导顺序是 `MULTICA_DAEMON_SERVER_URL` → `MULTICA_PUBLIC_URL` → `MULTICA_APP_URL`
（见 `server/internal/handler/config.go` 的 `daemonSetupURLsFromEnv`）。
不设置会回退到**前端 origin**，而 daemon 并不访问 Next.js —— 它直接对 Go 后端说
`/api/daemon/*`。结果是远程 agent **注册到错误的入口，永远领不到任务，日志里也没有任何提示**。

```
$ curl -s http://192.168.50.248:3000/api/config | grep daemon_server_url
"daemon_server_url": "http://192.168.50.248:3000"
```

**2. Caddy 转发 `/api/daemon/*`**

backend 只绑定 `127.0.0.1:8080`（**故意如此**，避免 Docker 绕过 macOS 防火墙把后端暴露到局域网）。
所以远程 daemon 必须经 Caddy：

```
/api/daemon/*  → multica-backend:8080（含 WebSocket /api/daemon/ws）
/ws            → multica-backend:8080（浏览器实时更新）
其余            → multica-frontend:3000
```

验证（应返回 401 且带后端 CSP 头，而不是前端 HTML）：

```bash
curl -s --noproxy '*' -i http://192.168.50.248:3000/api/daemon/runtimes | head -8
# 期望：HTTP/1.1 401 + X-Middleware-Rewrite: http://backend:8080/api/daemon/runtimes
```

> **若缺这条规则会怎样**：请求落到前端（返回 404 或 HTML），daemon 注册后静默失效 ——
> 界面看起来正常，只是永远没有 runtime 上线。接入开发机前先用上面的 curl 确认这条路由。

## 运维

```bash
# 状态与日志
docker compose ps
docker compose logs -f backend
docker compose logs -f frontend

# 健康检查
curl -s http://localhost:8080/health    # 存活
curl -s http://localhost:8080/readyz    # 含 db 与 migrations 状态

# 数据库
docker compose exec postgres psql -U multica -d multica

# 升级（会重新拉取镜像并原地迁移，迁移是幂等的）
bash deploy.sh

# 重启单个服务
docker compose up -d --force-recreate frontend
```

## 数据与持久化

| 卷 | 内容 |
|:---|:---|
| `multica_pgdata` | PostgreSQL 数据（账号、workspace、issue、评论、运行记录） |
| `multica_backend_uploads` | 上传的附件 |
| `caddy_data` / `caddy_config` | 反代证书与状态（HTTP-only 时未使用） |

`stop.sh` **不会**删除卷（加 `-v` 才会，且不可逆）。

按 CLAUDE.md 的原则，这些卷视为**可从配置重建**：版本化的是 `deploy.sh` +
`.env.example` + 本 README，而不是数据库 dump。重建路径即重新部署 + 重新登录配置。

## 排错

| 现象 | 原因与处理 |
|:---|:---|
| 局域网能开页面，但实时功能失效、console 循环 `disconnected, reconnecting in 3s` | 最典型的问题，按序检查：① `.env` 的 `CORS_ALLOWED_ORIGINS` 是否等于浏览器实际 origin；② `../caddy/Caddyfile` 的 `/ws` 块是否命中；③ `flush_interval -1` 是否存在。后端日志关键字 `websocket: request origin not allowed by Upgrader.CheckOrigin` |
| 升级后界面能开但数据请求全 404 | `NEXT_PUBLIC_API_URL` 被设成了带路径的值。它只接受 origin（scheme + host + port），**不能带 `/api`**。本节点默认留空以使用同源相对路径 |
| 页面能加载但任何写操作都 403 `CSRF validation failed` | Cookie 跨域问题。本部署采用同源单布局，正常不会出现；若出现，检查是否误设了 `NEXT_PUBLIC_API_URL` 指向另一个 host |
| `docker pull` 卡住或 `EOF` | Docker Hub 不可达。跑 `../config/set-docker-mirror.sh` 并重启 Docker Desktop |
| Multica 镜像拉取失败 | mirror 可能不代理 GHCR。`deploy.sh` 已自动回退直连；仍失败则清空 `.env` 的 `GHCR_MIRROR` 或改用 `--build` |
| backend 起不来、`/readyz` 的 `migrations` 非 ok | 迁移仍在跑或失败。`docker compose logs backend` 查看；`MULTICA_DATABASE_STARTUP_TIMEOUT` 默认 3 分钟 |
| 端口被占用 | `deploy.sh` 启动前会检测并打印占用进程。改 `.env` 的 `BACKEND_PORT` / `FRONTEND_PORT`（后者还需同步 `../caddy/Caddyfile` 的上游端口） |
| 登录码收不到 | 未配 SMTP/Resend 时验证码只在日志里：`docker logs multica-backend \| grep "Verification code"` |
| daemon 显示未运行 | `multica daemon status`、`multica daemon logs -n 100`。确认 `claude` 在 PATH 上且已登录 |
| 容器内 `curl`/`wget` 测任何地址都返回 502 | Docker Desktop 把宿主系统代理注入到了容器里。测试命令加 `--noproxy '*'`。注意这只影响测试，不是服务故障 —— 但反代本身也受此影响，见 `../caddy/README.md` |
| `docker compose up -d` 后改动没生效 | 仅挂载文件变化时 Compose 认为容器无变化，不会重建。用 `--force-recreate` 或 `docker compose restart <service>` |

## 已知限制

- **不启用 TLS。** 局域网 IP 无法签发公网证书。若需 TLS 或公网访问，
  需重新评估证书策略、`COOKIE_DOMAIN` 与 Origin 白名单；本方案的同源单布局届时仍适用。
- **dsh 不可用**，原因见上。
- **IP 硬编码在两个位置**（`.env` 的 `FRONTEND_ORIGIN` 与 `CORS_ALLOWED_ORIGINS`），
  变更需手工同步并重启后端。`../caddy/Caddyfile` 不含 IP。
- **无高可用**：单机单实例，容器 `restart: unless-stopped` 负责进程级自愈。
  宿主机重启后 Docker Desktop 需自行启动（Settings → General →
  "Start Docker Desktop when you sign in"）。

## 维护记录

| 日期 | 事项 | 说明 |
|:---|:---|:---|
| 2026-05-24 | 初始部署 | 由上游 compose 派生独立副本；caddy 作为平级服务容器化部署；配置 GHCR 镜像加速与 Docker Hub mirror |