# Claude Code CLI container configured for local SGLang endpoints.
# SGLang natively serves Anthropic /v1/messages — no proxy needed.
#
# Build:
#   docker build -f nodes/ubuntu26-node1-server/game-server/config/claude-code.dockerfile \
#       -t server-forge/claude-code:latest .
#
# Run (point ANTHROPIC_BASE_URL at any SGLang instance):
#   docker run --rm --network host \
#       -v "$(pwd):/workspace" -w /workspace \
#       -e ANTHROPIC_BASE_URL="http://localhost:8001" \
#       server-forge/claude-code:latest \
#       claude -p "Say hello."

FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# ── Endpoint: SGLang native Anthropic API (:8001 = MoE, :8000/:8002 = 27B Dense) ──
ENV ANTHROPIC_BASE_URL="http://localhost:8001"
ENV ANTHROPIC_API_KEY="not-needed"

# ── Model mapping (SGLang served-model-name values) ──
ENV ANTHROPIC_DEFAULT_OPUS_MODEL="Qwen3.6-27B-FP8"
ENV ANTHROPIC_DEFAULT_SONNET_MODEL="Qwen3.6-35B-A3B-FP8"
ENV ANTHROPIC_DEFAULT_HAIKU_MODEL="Qwen3.6-35B-A3B-FP8"

# ── Capability overrides ──
ENV CLAUDE_CODE_DISABLE_THINKING=1
ENV DISABLE_PROMPT_CACHING=1
ENV CLAUDE_CODE_MAX_CONTEXT_TOKENS=32768

# ── Friendly display names ──
ENV ANTHROPIC_DEFAULT_OPUS_MODEL_NAME="Qwen3.6 27B (GPU 0/2)"
ENV ANTHROPIC_DEFAULT_SONNET_MODEL_NAME="Qwen3.6 35B MoE (GPU 1)"
ENV ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME="Qwen3.6 35B MoE (GPU 1)"

# Prevent interactive setup prompts
ENV CLAUDE_CODE_AUTO_ACCEPT_WARNING=1

WORKDIR /workspace
ENTRYPOINT ["claude"]
