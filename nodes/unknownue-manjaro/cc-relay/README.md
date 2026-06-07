# cc-relay — Claude Code 多模型代理

## 概述

cc-relay 是一个多提供商 LLM 代理，运行在 Claude Code 客户端与多个 AI 后端之间。
支持按模型名将请求路由到不同提供商（Anthropic、Ollama、Bedrock 等），
实现速率限制池化、自动故障转移和成本优化。

### 为什么需要它

Claude Code 原生只能连接一个 API 端点。cc-relay 实现：

- 单一入口，多后端路由（本地模型 + 远程 API 混合使用）
- 多个 Anthropic API key 速率限制池化
- 自动故障转移（Anthropic 不可用时切换到本地 Ollama）
- 按模型名智能路由（复杂任务走远程大模型，简单任务走本地小模型）

## 架构

```
Claude Code ──→ cc-relay (127.0.0.1:8787) ──→ claude-opus-4-6  → Anthropic API (远端)
                                    │
                                    ├── claude-sonnet-* → Ollama localhost:11434
                                    │
                                    └── (failover) Anthropic 不可用 → Ollama
```

当前配置：`strategy: failover` — Anthropic 主用，Ollama 备用。

## 文件

| 文件 | 说明 |
|:---|:---|
| `config.yaml` | cc-relay 主配置文件 |
| `Dockerfile` | 多阶段构建（Go 编译 + Alpine 运行时） |
| `build.sh` | 构建 Docker 镜像 |
| `deploy.sh` | 启动 cc-relay 容器 |
| `stop.sh` | 停止并删除 cc-relay 容器 |

## 快速开始

### 1. 初始化 submodule（首次）

```bash
cd /path/to/server-forge
bash scripts/setup-submodules.sh
```

### 2. 构建镜像

```bash
bash nodes/unknownue-manjaro/cc-relay/build.sh
```

### 3. 设置 API Key

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### 4. 启动

```bash
bash nodes/unknownue-manjaro/cc-relay/deploy.sh
```

### 5. 配置 Claude Code 使用代理

```bash
export ANTHROPIC_BASE_URL=http://localhost:8787/v1
export ANTHROPIC_API_KEY=not-needed
```

### 6. 停止

```bash
bash nodes/unknownue-manjaro/cc-relay/stop.sh
```

## 配置说明

### 路由策略

配置位置：`config.yaml` → `routing.strategy`

| 策略 | 行为 | 适用场景 |
|:---|:---|:---|
| `failover`（当前） | 按优先级依次尝试，失败切换下一个 | 远端 API 为主，本地模型为兜底 |
| `model_based` | 按模型名前缀匹配路由到指定 provider | 不同模型走不同服务器 |
| `round_robin` | 轮询分发 | 多 key 负载均衡 |
| `shuffle` | 随机分发 | 多 key 随机均衡 |

### 按模型路由到不同服务器（model_based）

将 `routing.strategy` 改为 `model_based`，配置示例：

```yaml
routing:
  strategy: "model_based"
  model_mapping:
    claude-opus: anthropic         # claude-opus-* → Anthropic API
    claude-sonnet: ollama-local    # claude-sonnet-* → 本地 Ollama
    qwen: ollama-remote            # qwen* → 远端 Ollama 服务器
    deepseek: ollama-deepseek      # deepseek* → 另一台服务器
  default_provider: anthropic      # 未匹配时默认走 Anthropic
```

然后在 `providers` 中定义多个 Ollama 实例指向不同服务器：

```yaml
providers:
  - name: "anthropic"
    type: "anthropic"
    enabled: true
    models:
      - "claude-opus-4-6"
      - "claude-sonnet-4-5-20250514"
    keys:
      - key: "${ANTHROPIC_API_KEY}"

  - name: "ollama-local"
    type: "ollama"
    enabled: true
    base_url: "http://localhost:11434"
    model_mapping:
      "claude-sonnet-4-5-20250514": "qwen3:32b"
      "claude-haiku-4-5-20251001": "qwen3:8b"

  - name: "ollama-remote"
    type: "ollama"
    enabled: true
    base_url: "http://192.168.1.100:11434"
    model_mapping:
      "claude-opus-4-6": "qwen3:72b"

  - name: "ollama-deepseek"
    type: "ollama"
    enabled: true
    base_url: "http://192.168.1.101:11434"
    model_mapping:
      "deepseek-v4": "deepseek-v4-flash"
```

修改配置后重启容器生效。

### 提供商类型

| type | 说明 | 必需参数 |
|:---|:---|:---|
| `anthropic` | Anthropic 官方 API | `keys` |
| `ollama` | Ollama 本地/远程服务 | `base_url` |
| `zai` | Z.AI / 智谱 GLM | `base_url`（默认 `https://api.z.ai/anthropic`） |
| `minimax` | MiniMax | `base_url`（默认 `https://api.minimax.io/anthropic`） |
| `bedrock` | AWS Bedrock | `aws_region` + AWS 凭证 |
| `azure` | Azure AI Foundry | `azure_resource_name` + `keys` |
| `vertex` | Google Vertex AI | `gcp_project_id` + `gcp_region` |

同类型可定义多个实例指向不同 `base_url`，无名额限制。

### Model Mapping 格式

每个 provider 的 `model_mapping` 将 Claude 模型名映射到实际后端模型名：

```yaml
model_mapping:
  "claude-opus-4-6": "qwen3:72b"               # Claude Code 请求的模型名 → Ollama 实际模型
  "claude-sonnet-4-5-20250514": "qwen3:32b"
```

支持前缀匹配（`model_based` 策略）：`claude-opus` 匹配所有 `claude-opus-*` 请求。

### 认证

当前配置 `allow_subscription: true`，允许 Claude Code 订阅用户通过代理连接。

可选其他认证方式：
- `api_key` — 要求客户端携带 `x-api-key` 请求头
- `allow_bearer` — 接受 Bearer token

## 运维

### 查看日志

```bash
docker logs -f cc-relay
```

### 查看指标

```bash
curl http://localhost:9100/metrics
```

### 健康检查

cc-relay 每 10 秒探测所有 provider 健康状态。连续失败 5 次触发断路器，
30 秒后半开重试，3 次探测全部通过则恢复。

### 更新配置

1. 编辑 `nodes/unknownue-manjaro/cc-relay/config.yaml`
2. 重启容器：`bash nodes/unknownue-manjaro/cc-relay/deploy.sh`

注：cc-relay 规划支持配置热重载（Phase 7），当前版本需重启生效。

### 更新二进制

cc-relay 作为 submodule 管理。更新步骤：

```bash
cd submodules/cc-relay
git pull origin main
cd ../..
# 重新构建
bash nodes/unknownue-manjaro/cc-relay/build.sh
# 重新部署
bash nodes/unknownue-manjaro/cc-relay/deploy.sh
```

## 故障排除

| 问题 | 原因 | 解决 |
|:---|:---|:---|
| 容器无法启动 | 镜像未构建 | 先执行 `build.sh` |
| Anthropic API 返回 401 | `ANTHROPIC_API_KEY` 未设置或无效 | 检查 key 并重新 `deploy.sh` |
| Ollama 路由失败 | Ollama 服务未运行或 `base_url` 不可达 | 确认 `ollama serve` 在目标机器运行 |
| 断路器打开 | Provider 连续失败超过阈值 | 等待自动恢复（30s），或重启容器 |
| 所有 provider 不可用 | 网络问题或 key 耗尽 | 检查网络，轮换 key |
