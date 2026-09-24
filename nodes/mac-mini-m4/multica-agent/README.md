# multica-agent — 容器化的 Multica 运行时（daemon + dsh）

在**开发机**上以容器方式运行 Multica 的 agent 运行时：`multica` daemon 与
`dsh`（DeepSeek Harness）都在同一个容器内。

> **部署位置**：这台是**开发机**，不是跑 Multica 服务端的机器。
> 服务端在 `mac-mini-m4`（见 `../multica/README.md`）。

## 为什么 daemon 要进容器

上游文档把容器列为**推荐的隔离边界**（`security-model.mdx`）：

> 2. **Container.** Run the daemon in a container with only the mounts and secrets the agents need.

原因是 Multica **不对 agent 做文件系统沙箱**。同一份文档写得很直接：

> If the daemon runs as your personal user account, a run can read your SSH keys,
> edit your shell profile, and delete your documents. Isolation has to come from
> the boundary you put the daemon in.

而这个容器就是这个边界。

## 与宿主机 dsh 的隔离机制

这是本方案的核心诉求：**容器里的 dsh 可以任意改动，宿主机上的 dsh 只有用户维护。**

靠的是 `DSH_HOME`，不是靠约定。Multica 从 `DSH_HOME` 解析 profile 存储位置
（`server/internal/daemon/dsh_profile.go`），dsh 自身也认这个变量：

| | 宿主机 dsh | 容器内 dsh |
|:---|:---|:---|
| `DSH_HOME` | `~/.dsh` | `/dsh-home` |
| 存储 | 宿主机文件系统 | **命名卷 `multica-agent-dsh-home`** |
| profile | 你维护的 `web` 等 | 镜像内构建的 `multica` |
| 可改动性 | **只有你能改** | 容器内随便改，**宿主不可见** |

容器**从不挂载** `~/.dsh`，所以这不是"两个目录分开存"，而是文件系统级别的不可达。
即使 agent 在容器里重写自己的运行时，宿主机的 dsh 也丝毫不受影响。

## 架构

```
开发机（本目录所在机器）
└── docker compose: multica-agent
    └── multica-agent 容器
        ├── /repos       ← 绑定挂载宿主机仓库（读写，工作产物落这里）
        ├── /dsh-home    ← 命名卷，容器私有 DSH_HOME
        ├── /multica-home← 命名卷，PAT 配置与会话状态
        ├── multica daemon（连服务端 /api/daemon/*）
        └── dsh --profile multica --stdio
                │
                └── 本地模型端点（可选，dsh 侧配置）

        │ LAN
        ▼
mac-mini-m4:3000 (Caddy) ──→ multica-backend
```

## 为什么需要自己构建镜像

Multica 通过 `dsh --profile multica --stdio` 驱动 DSH，而**这个协议不在 DSH 本体里**。
`dsh.go` 的注释说明了原因：

> DSH ships no machine-drivable mode of its own. `--profile headless` answers one
> task and exits, and ACP — the one protocol DSH does implement — is itself a
> profile rather than a built-in.

所以裸的 `dsh` 能打印版本号但**无法执行任务**。协议由 Multica 的 runtime bundle
提供，而它**没有发布到 npm**（[multica#6936](https://github.com/multica-ai/multica/issues/6936)），
因此本镜像从源码构建它。

## 文件

| 文件 | 说明 |
|:---|:---|
| `Dockerfile` | 三阶段构建：取 CLI → 编译 bridge → 运行时镜像 |
| `entrypoint.sh` | headless 认证、profile 校验、启动 daemon |
| `docker-compose.yml` | 挂载与隔离边界定义 |
| `.env.example` | 配置模板（`.env` 不入库） |
| `deploy.sh` | 部署：校验 → 构建 → 验证 → 启动 |
| `stop.sh` | 停止（保留状态卷） |
| `bridge/` | Multica DSH runtime bridge 源码（从上游获取后入库） |

`bridge/` 已纳入本仓库，因为 `github.com` 在部分网络下不可达（见下），
把源码入库可让构建不依赖外网获取该仓库。

## 快速开始

```bash
# 1. 首次运行会生成 .env 并提示填写
bash deploy.sh

# 2. 编辑 .env，填三项必填值
#    MULTICA_SERVER_URL=http://192.168.50.248:3000
#    MULTICA_TOKEN=mul_...        ← 在 Web UI 的 Settings → API Token 创建
#    REPOS_DIR=/home/you/projects ← agent 可改的仓库目录

# 3. 真正部署
bash deploy.sh

# 4. 查看状态
docker compose logs -f agent
docker compose exec agent multica daemon status
```

停止：

```bash
bash stop.sh
```

## 创建 PAT（必填，容器无浏览器）

容器里跑不了 `multica login` —— 它需要浏览器完成 OAuth。文档给出的 headless 正解
（`auth-tokens.mdx`）：

> On a machine without a browser, create a PAT on the web first and let the CLI
> prompt for it safely

步骤：

1. 浏览器打开 `http://192.168.50.248:3000` 并登录
2. **Settings → API Token** → 创建（名称任意，有效期建议 90 天）
3. **完整 token 只显示一次**，立刻复制
4. 填进 `.env` 的 `MULTICA_TOKEN=mul_...`

> token 等同于密码：它可访问你账号下的所有 workspace 与 API。
> `.env` 已设为 600 权限并被 git 忽略。

## 关于本地模型

**dsh 容器本身不跑模型**，它只是调用模型端点。本地方案下：

```
dsh 容器 ──→ 本地模型端点（如 SGLang / vLLM）
```

这属于 **dsh 侧配置**，Multica 不感知——这也是选 dsh 而非 Claude Code 的优势：
模型目录由 dsh 自己管理（`dsh --profile multica --list-models`），
不需要让本地模型去模仿 Anthropic API。

> 若首次运行时 `--list-models` 为空，说明 dsh 还没有可用的 provider/model 配置。
> 参照 DSH 自身文档配置 provider 指向你的本地端点。

## 安全边界

| 项 | 说明 |
|:---|:---|
| 可写范围 | **仅 `/repos`**（绑定挂载）。其余文件系统改动随容器销毁 |
| SSH key | 容器内**没有**宿主机的 `~/.ssh`（未挂载） |
| 宿主机 dsh | **不可达**（`DSH_HOME` 指向容器卷） |
| 网络 | 默认 bridge，不占 LAN 端口；仅主动外连服务端 |
| PAT | 存在 `multica-agent-home` 卷内，权限 600 |

> `deploy.sh` 会**拒绝** `REPOS_DIR` 为 `/` 或 `$HOME`，因为那会把开发者的
> 凭据、SSH key、文档全部暴露给每一次 agent 运行——正是容器化要避免的事。

## 排错

| 现象 | 原因与处理 |
|:---|:---|
| `cannot reach .../health` | 服务端未启动，或 URL 指向了 backend 的 8080（那是服务端环回，外部够不着）。应为 Caddy 的 3000 |
| `daemon API returned 404` | 服务端 Caddy 缺少 `/api/daemon/*` 转发。在服务端更新 `caddy/Caddyfile` 后重跑 `caddy/deploy.sh` |
| `MULTICA_TOKEN is not set` | 未创建 PAT。见上文「创建 PAT」 |
| 构建时下载 CLI 失败 | `github.com` 不可达但 `api.github.com` 通。设置 `GH_PROXY` 指向镜像前缀 |
| `pnpm not found` | 只会在手动进容器构建 bridge 时出现；镜像构建阶段已装 pnpm |
| `dsh --profile multica --probe` 无输出/非 v1 | bridge 未正确安装。`docker compose run --rm --entrypoint sh agent` 进容器排查 |
| daemon running 但 Runtimes 里没有 | 至少需要一个被探测到的 agent CLI。dsh 需 `--probe` 成功（本镜像已在构建时校验） |
| 容器 Up 但服务端显示离线 | daemon 未能认证。`docker compose logs agent` 查 PAT 是否有效/过期 |
| 构建很慢 | 首次要编译 bridge 并装 DSH 全家桶，属正常；后续层有缓存 |

## 已知限制

- **镜像需自行构建。** 无官方 daemon 镜像（Helm chart 只含 backend/frontend/postgres）。
- **DSH 版本不能随意升。** bridge 针对 `dsh@0.1.0-rc.6` 验证；新版会引入未发布的传递依赖，
  详见下文「版本约束」。`DSH_VERSION` 与 `DSH_SANDBOX_VERSION` 必须同版本。
- **`bridge/` 是手动同步的上游快照。** 更新方式见 `bridge/README.md`。
- **不自动更新。** 升级用 `bash deploy.sh --build`。
- **无 GPU 直通。** 模型端点在容器外；若要在容器内跑推理，需额外配置 `--gpus`
  与 nvidia-container-toolkit。

## 版本约束（重要）

这是本方案最容易踩的坑，且**失败方式是静默的**：

`dsh-base` 把 `@deepseek-ai/dsh-sandbox-local` 声明为 `^<版本>`。若 dsh 用较新的版本，
该范围会解析到一个传递依赖里含 **`@deepseek-ai/dsh-type-meta`** 的
`sandbox-local` —— 而这个包**从未发布到 npm**（404）。后果是：

1. `pnpm` 以 `ERR_PNPM_FETCH_404` 失败
2. `dsh plugin add` **回滚整个 profile 目录**
3. 但 `dsh --profile multica --probe` **仍然返回 `protocol_version: 1`**
4. 结果：Multica **成功注册 runtime**，然后**每个任务都失败**：

```
multica-dsh-runtime: DSH session service is unavailable
{"type":"protocol_error","code":"STARTUP_FAILED", ...}
```

第 3 步是关键：bridge 在插件树加载完成**之前**就发出了 probe 帧，所以**只查 probe
无法发现这个问题**。

**因此 `Dockerfile` 与 `entrypoint.sh` 都强制做一次真实的 stdio 握手**，
断言不出现 `STARTUP_FAILED`。这个检查在排查过程中确实抓到过上述故障。

修复方式：把 `DSH_VERSION` 与 `DSH_SANDBOX_VERSION` 钉在同一版本
（当前 `0.1.0-rc.6`），并让 profile 允许 `koffi` 的构建脚本。

> 关于 pnpm 配置：正确的键是 profile 的 `pnpm-workspace.yaml` 里的
> **`allowBuilds`，且必须是映射形式**（`koffi: true`）。
> 写成列表会报 `unexpected event: expected mapping start`；
> 写成 `onlyBuiltDependencies` 则被**静默忽略**，构建仍然被阻塞。
> DSH 自己的报错文本指明了正确位置。

## 排错

| 现象 | 原因与处理 |
|:---|:---|
| `cannot reach .../health` | 服务端未运行，或 URL 指向了 backend 的 8080（那是服务端环回，外部够不着）。应为 Caddy 的 3000 |
| `daemon API returned 404` | 服务端 Caddy 缺少 `/api/daemon/*` 转发。在服务端更新 `caddy/Caddyfile` 后重跑 `caddy/deploy.sh` |
| `MULTICA_TOKEN is not set` | 未创建 PAT。见上文「创建 PAT」 |
| `REPOS_DIR must not be ...` | 指向了 `$HOME` 或 `/`，被安全校验拒绝（这是有意设计） |
| 构建时 `apt-get`/`pnpm` 连不上 | 容器出网被代理劫持。检查 `~/.docker/config.json` 有无 `proxies.default` 指向**不存在的**代理；有则删除后重建 |
| 构建时下载 CLI 失败 | `github.com` 不可达但 `api.github.com` 通。`fetch-cli.sh` 已自动改走 Assets API；全不通时设 `GH_PROXY` |
| 构建报 `ERR_PNPM_FETCH_404 ... dsh-type-meta` | dsh 版本过新，见上文「版本约束」 |
| 构建报 `STARTUP_FAILED` | 同上；或 profile 安装被回滚。检查 `allowBuilds` 配置 |
| 容器 Up 但 Runtimes 无此机器 | PAT 无效/过期。`docker compose logs agent`；重建 token 并更新 `.env` 后 `docker compose up -d --force-recreate agent` |
| 注册成功但任务必失败 | 多半是上面那个 probe 假阳性的场景。手动验证：`docker compose exec agent sh -c 'echo "{\"v\":1,\"type\":\"execute\",\"request_id\":\"t\",\"cwd\":\"/tmp\",\"prompt\":\"x\",\"mcp_servers\":[]}" \| dsh --profile multica --stdio'`，若出现 `STARTUP_FAILED` 则 profile 有问题 |
| 模型下拉框为空 | dsh 侧还没配 provider。`docker compose exec agent dsh --profile multica --list-models` 查看 |

## 维护记录

| 日期 | 事项 | 说明 |
|:---|:---|:---|
| 2026-05-24 | 初始部署 | 容器化 daemon + dsh；bridge 从上游源码构建；以 `DSH_HOME` 命名卷实现与宿主机 dsh 的文件系统隔离 |
| 2026-05-24 | 修复构建与运行时故障 | 三处阻塞：(1) `~/.docker/config.json` 的失效代理导致容器内 `apt`/`pnpm` 全部失败；(2) `github.com` 不可达，改为经 Assets API 下载 CLI；(3) dsh 版本过新导致 `sandbox-local` 解析到含未发布依赖的版本 —— 钉到 `0.1.0-rc.6` 并配置 pnpm `allowBuilds` 解决。新增 stdio 冒烟测试，因为 `--probe` 无法发现该故障 |