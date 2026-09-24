# 远程开发机接入 Multica — 操作指示

本文件是**在局域网开发机上执行**的步骤。Multica 服务端运行在 `mac-mini-m4`，
本机不装 daemon。

## 拓扑

```
┌─────────────────────────┐         ┌──────────────────────────────────┐
│ mac-mini-m4             │         │ 开发机（本指示的执行对象）        │
│ （服务端，已完成部署）   │         │                                  │
│                         │  LAN    │  docker compose: multica-agent   │
│ caddy :3000             │◀────────│   └── multica-agent 容器         │
│  ├ /api/daemon/* → backend        │       ├── daemon                 │
│  ├ /ws           → backend        │       ├── dsh --profile multica  │
│  └ 其余          → frontend       │       └── /repos ← 你的仓库       │
│                         │         │                                  │
│ multica-backend :8080   │         │  本地模型端点（可选）             │
│ multica-postgres        │         │                                  │
└─────────────────────────┘         └──────────────────────────────────┘
```

**关键点**：daemon 通过 `http://192.168.50.248:3000` 访问服务端，
由 Caddy 把 `/api/daemon/*` 转发给 backend。**不要**用 8080 —— 它只绑服务端环回。

## 前置条件

| 项 | 要求 |
|:---|:---|
| Docker | 已安装且 `docker compose` v2 可用 |
| 网络 | 能访问 `192.168.50.248:3000` |
| 磁盘 | 镜像约 1.5 GB，另需仓库空间 |
| 架构 | `uname -m` 确认：`x86_64` → amd64，`aarch64`/`arm64` → arm64 |

验证网络连通（在开发机上执行）：

```bash
curl -sf --noproxy '*' http://192.168.50.248:3000/health && echo "OK"
```

若不通，检查服务端是否在运行、以及本机能否路由到该网段。

## 步骤 1 — 在服务端创建 PAT

**这一步在浏览器里做**，因为容器没有浏览器，无法走 `multica login` 的 OAuth 流程。

1. 打开 `http://192.168.50.248:3000` 并登录
2. 进入 **Settings → API Token**
3. 点击创建，名称随意（建议含机器名，如 `dev-box-1`），有效期建议 90 天
4. **完整 token 只显示一次**，立即复制

> token 形如 `mul_xxxxxxxx`，等同于密码 —— 可访问你账号下所有 workspace 与 API。
> 不要放进 git、issue、评论或截图中。

## 步骤 2 — 准备仓库目录

确定 agent 可以改哪个目录。**范围越小越好**：

```bash
# 好：只放需要 agent 参与的仓库
mkdir -p ~/multica-repos
# 把要 agent 参与的仓库放进来（或 clone 进来）
```

不要用 `$HOME` 或 `/`——那会把 SSH key、凭据、文档全部暴露给每次运行。
`deploy.sh` 会拒绝这类值。

## 步骤 3 — 部署 agent 运行时

把 `nodes/mac-mini-m4/multica-agent/` 这个目录复制到开发机（或从本仓库 checkout），然后：

```bash
cd multica-agent

# 首次运行会生成 .env 并提示填三项
bash deploy.sh
```

编辑 `.env`：

```bash
MULTICA_SERVER_URL=http://192.168.50.248:3000
MULTICA_APP_URL=http://192.168.50.248:3000
MULTICA_TOKEN=mul_...            # 步骤 1 复制的
REPOS_DIR=/home/you/multica-repos # 步骤 2 的目录，必须用绝对路径
TARGETARCH=amd64                  # 按 uname -m 填
```

然后正式部署：

```bash
bash deploy.sh
```

`deploy.sh` 会依次：检查前置条件 → 校验 `.env` → **探测服务端与 daemon API 可达性**
→ 构建镜像 → **校验容器内 dsh profile 可用** → 启动 → 报告状态。

任何一步失败都会**中止并给出原因**，不会留下半启动状态。

## 步骤 4 — 验证

```bash
# 容器在跑
docker compose ps

# daemon 状态（应显示 running 及检测到的 agent）
docker compose exec agent multica daemon status

# 实时日志
docker compose logs -f agent
```

然后在浏览器打开 `http://192.168.50.248:3000` →
**Settings → Runtimes**，应该看到这台机器上线。

## 步骤 5 — 创建 agent 并跑第一次任务

1. **Settings → Agents → New agent**
2. Runtime 选刚上线的那台
3. Provider 选 **DeepSeek Harness**（dsh）
4. 如果模型下拉框为空，说明 dsh 还没有可用的 provider/model 配置 —— 见下节
5. 建一个 issue，assignee 选这个 agent

## 本地模型配置

**dsh 容器本身不跑模型**，它只是调用模型端点。要让它用局域网内的本地模型，
需要在 dsh 侧配置 provider 指向你的端点。

查看当前 dsh 能提供哪些模型：

```bash
docker compose exec agent dsh --profile multica --list-models
```

若为空，说明还没有配置 provider。dsh 的 provider 配置方式参照 DSH 自身文档
（`dsh --help`、`dsh plugin`）。配置好后重启容器：

```bash
docker compose restart agent
```

Multica 侧的模型 id 使用 `provider/model` 形式（如 `local/qwen3-coder`），
从 `--list-models` 的输出里选完整 id。

## 与宿主机 dsh 的隔离

如你在这台机器上**自己也在用 dsh**，请放心：容器与你的 dsh 完全隔离。

| | 你的 dsh | 容器内 dsh |
|:---|:---|:---|
| `DSH_HOME` | `~/.dsh` | `/dsh-home` |
| 存储位置 | 本机文件系统 | Docker 命名卷 `multica-agent-dsh-home` |
| 挂载关系 | — | **容器从不挂载 `~/.dsh`** |

所以容器里的 dsh 可以任意改动 profile、装插件、改配置，**你的 `~/.dsh` 完全不受影响**。
这是文件系统级别的隔离，不是约定。

## 日常运维

```bash
# 状态与日志
docker compose ps
docker compose logs -f agent
docker compose exec agent multica daemon status

# 重启（会重新探测本机 agent CLI）
docker compose restart agent

# 暂停（保留状态卷）
bash stop.sh

# 升级镜像
bash deploy.sh --build
```

## 排错

| 现象 | 原因与处理 |
|:---|:---|
| `cannot reach .../health` | 服务端未运行，或 URL 写成了 `:8080`。应为 `:3000` |
| `daemon API returned 404` | 服务端 Caddy 缺少 `/api/daemon/*` 转发规则。需在服务端更新 `caddy/Caddyfile` 并重跑 `caddy/deploy.sh` |
| `MULTICA_TOKEN is not set` | 未执行步骤 1 |
| `REPOS_DIR does not exist` | 路径写错，或用了相对路径 |
| `REPOS_DIR must not be ...` | 指向了 `$HOME` 或 `/`，被安全校验拒绝 |
| 构建时 `apt-get`/`pnpm` 超时 | 容器的出网被代理劫持。检查 `~/.docker/config.json` 是否有 `proxies.default` 指向不存在的代理；有则删除后重建 |
| 构建时下载 CLI 失败 | `github.com` 不可达。在 `.env` 设 `GH_PROXY` 指向镜像前缀 |
| `dsh multica profile` 校验失败 | bridge 未正确构建。`docker compose run --rm --entrypoint sh agent` 进容器排查 |
| 容器 Up 但 Runtimes 无此机器 | PAT 无效或过期。`docker compose logs agent` 查看；重新创建 token 并更新 `.env` 后重启 |
| daemon running 但无 detected agents | dsh profile 未通过 probe。用上面的进容器方式排查 |
| 改了 `.env` 不生效 | `docker compose up -d --force-recreate agent` |

## 需要新增能力时

若要让 agent 用上其他 AI CLI（如 `claude`、`codex`），在那个容器里安装即可 ——
它们同样是容器私有的，不会影响宿主机。装完重启：

```bash
docker compose exec agent bash
# 在容器内安装（示例）
npm install -g @anthropic-ai/claude-code
exit
docker compose restart agent
```

但注意：容器重建后这些改动会丢失（除非扩展 Dockerfile）。
持久化的做法是在 `Dockerfile` 里加上安装步骤，然后 `bash deploy.sh --build`。