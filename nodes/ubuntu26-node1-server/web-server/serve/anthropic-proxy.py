#!/usr/bin/env python3
"""
Anthropic Messages API ↔ OpenAI Chat Completions API translation proxy.
Accepts both formats simultaneously on a single port.

Endpoints:
  POST /v1/messages           Anthropic → translated → SGLang (OpenAI)
  POST /v1/chat/completions   OpenAI passthrough → SGLang
  GET  /v1/models              Model list (OpenAI format)
  GET  /health                 Health check

Model routing:
  Exact match in BACKENDS dict, then fuzzy by model name keywords:
    "35B" / "A3B" / "MoE" → :8001 (MoE, high throughput)
    "27B" / "72B" / "32B"  → :8000 (Dense, default)
    everything else        → DEFAULT_BACKEND (:8000)

Real model names (primary):
  Qwen3.6-27B-FP8        → :8000
  Qwen3.6-35B-A3B-FP8    → :8001

Anthropic aliases (fallback):
  claude-opus-4-7         → :8000
  claude-sonnet-4-6       → :8001
  claude-haiku-4-5        → :8002

Config via env vars:
  BACKEND_8000, BACKEND_8001, BACKEND_8002  — SGLang endpoint URLs
  DEFAULT_BACKEND  — fallback (default: BACKEND_8000)
  PROXY_PORT       — listen port (default: 8090)
"""

import asyncio, json, os, re, sys, time

try:
    from aiohttp import web, ClientSession, ClientTimeout
except ImportError:
    print("ERROR: aiohttp required. pip install aiohttp", file=sys.stderr)
    sys.exit(1)

# ── Config ──
BACKENDS = {
    # Real model names (primary — set these in Claude Code env vars)
    "Qwen3.6-27B-FP8":       os.getenv("BACKEND_8000", "http://localhost:8000/v1"),
    "Qwen3.6-35B-A3B-FP8":   os.getenv("BACKEND_8001", "http://localhost:8001/v1"),
    "Qwen3-72B-FP8":          os.getenv("BACKEND_8000", "http://localhost:8000/v1"),
    "DeepSeek-R1-Distill-Qwen-32B-FP8": os.getenv("BACKEND_8000", "http://localhost:8000/v1"),
    # Anthropic aliases (fallback — for compatibility)
    "claude-opus-4-7":        os.getenv("BACKEND_8000", "http://localhost:8000/v1"),
    "claude-sonnet-4-6":      os.getenv("BACKEND_8001", "http://localhost:8001/v1"),
    "claude-haiku-4-5":       os.getenv("BACKEND_8002", "http://localhost:8002/v1"),
}
DEFAULT = os.getenv("DEFAULT_BACKEND", BACKENDS["Qwen3.6-27B-FP8"])
PORT = int(os.getenv("PROXY_PORT", "8090"))
TIMEOUT = ClientTimeout(total=600, connect=10)

FINISH_MAP = {"stop": "end_turn", "length": "max_tokens", "tool_calls": "tool_use"}

# Fuzzy routing patterns for unrecognized model names
FUZZY_ROUTES = [
    (re.compile(r"35B|A3B|MoE", re.I), "moe"),   # → :8001
    (re.compile(r"27B|72B|32B", re.I), "dense"),  # → :8000
]
MOE_BACKEND = os.getenv("BACKEND_8001", "http://localhost:8001/v1")


def resolve_backend(model_name: str) -> str:
    """Resolve backend URL for a model name. Exact match first, then fuzzy."""
    if model_name in BACKENDS:
        return BACKENDS[model_name]
    for pattern, category in FUZZY_ROUTES:
        if pattern.search(model_name):
            if category == "moe":
                return MOE_BACKEND
            return DEFAULT
    return DEFAULT


# ═══════════════════════════════════════════════════════════════════════
# Translation: Anthropic → OpenAI (request)
# ═══════════════════════════════════════════════════════════════════════

def anthropic_to_openai(body: dict) -> tuple[dict, str]:
    model = body.get("model", "")
    backend = resolve_backend(model)

    openai_msgs = []

    # system prompt
    sys_prompt = body.get("system")
    if sys_prompt:
        text = sys_prompt if isinstance(sys_prompt, str) else _extract_text(sys_prompt)
        if text:
            openai_msgs.append({"role": "system", "content": text})

    # messages with content block translation
    for msg in body.get("messages", []):
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if isinstance(content, list):
            openai_msgs.append({"role": role, "content": _translate_content_blocks(content)})
        else:
            openai_msgs.append({"role": role, "content": str(content) or ""})

    oai = {
        "model": model,
        "messages": openai_msgs,
        "max_tokens": body.get("max_tokens", 1024),
    }
    for k in ("temperature", "top_p", "top_k", "stream"):
        if k in body:
            oai[k] = body[k]
    if "stop_sequences" in body:
        oai["stop"] = body["stop_sequences"]

    tools = body.get("tools")
    if tools:
        oai["tools"] = [{
            "type": "function",
            "function": {"name": t["name"], "description": t.get("description", ""),
                         "parameters": t.get("input_schema", {})}
        } for t in tools]

    return oai, backend


def _extract_text(blocks: list) -> str:
    parts = []
    for b in blocks:
        if isinstance(b, dict) and b.get("type") == "text":
            parts.append(b.get("text", ""))
    return "\n".join(parts)


def _translate_content_blocks(blocks: list) -> list | str:
    """Anthropic content blocks → OpenAI content array. Returns plain string if text-only."""
    out = []
    for b in blocks:
        t = b.get("type", "")
        if t == "text":
            out.append({"type": "text", "text": b.get("text", "")})
        elif t == "image":
            src = b.get("source", {})
            if src.get("type") == "base64":
                mime = src.get("media_type", "image/png")
                out.append({"type": "image_url", "image_url": {
                    "url": f"data:{mime};base64,{src.get('data', '')}"}})
        elif t == "tool_use":
            out.append({"type": "text", "text": json.dumps({"tool_use": b})})
        elif t == "tool_result":
            out.append({"type": "text", "text": json.dumps({"tool_result": b})})
    if len(out) == 1 and out[0].get("type") == "text":
        return out[0]["text"]
    return out


# ═══════════════════════════════════════════════════════════════════════
# Translation: OpenAI → Anthropic (non-streaming response)
# ═══════════════════════════════════════════════════════════════════════

def openai_to_anthropic(oai_resp: dict, model: str) -> dict:
    choice = oai_resp.get("choices", [{}])[0]
    msg = choice.get("message", {})
    finish = choice.get("finish_reason")
    usage = oai_resp.get("usage", {})

    blocks = []
    text = msg.get("content", "")
    if text:
        blocks.append({"type": "text", "text": text})

    for tc in msg.get("tool_calls", []) or []:
        f = tc.get("function", {})
        try:
            args = json.loads(f.get("arguments", "{}"))
        except json.JSONDecodeError:
            args = {}
        blocks.append({"type": "tool_use", "id": tc.get("id", ""),
                       "name": f.get("name", ""), "input": args})

    return {
        "id": f"msg_{int(time.time()*1000)}",
        "type": "message",
        "role": "assistant",
        "content": blocks,
        "model": model,
        "stop_reason": FINISH_MAP.get(finish or "", "end_turn"),
        "stop_sequence": None,
        "usage": {"input_tokens": usage.get("prompt_tokens", 0),
                  "output_tokens": usage.get("completion_tokens", 0)},
    }


# ═══════════════════════════════════════════════════════════════════════
# Streaming translation: OpenAI SSE → Anthropic SSE
# ═══════════════════════════════════════════════════════════════════════

def _sse_event(event: str, data: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


async def _translate_stream(oai_stream, model: str):
    msg_id = f"msg_{int(time.time()*1000)}"
    started = False
    text_idx = 0
    tool_idx_base = 1
    current_tool_idx = -1
    current_tool_id = ""
    active_tool_indices = {}  # tool_call index → (block_index, id, name)
    finish_reason = None
    output_tokens = 0
    input_tokens = 0

    async for line in oai_stream:
        raw = line.decode("utf-8") if isinstance(line, bytes) else line

        if raw.startswith(":") or raw.strip() == "":
            yield (raw if raw.endswith("\n") else raw + "\n").encode()
            continue

        if not raw.startswith("data: "):
            continue

        payload = raw[6:].strip()
        if payload == "[DONE]":
            continue

        try:
            chunk = json.loads(payload)
        except json.JSONDecodeError:
            continue

        choices = chunk.get("choices", [{}])
        choice = choices[0] if choices else {}
        delta = choice.get("delta", {})
        finish_reason = choice.get("finish_reason") or finish_reason

        # usage snapshot (arrives in final chunk)
        u = chunk.get("usage", {})
        if u:
            input_tokens = u.get("prompt_tokens", input_tokens)
            output_tokens = u.get("completion_tokens", output_tokens)

        # ── message_start (first chunk only) ──
        if not started:
            started = True
            yield _sse_event("message_start", {
                "type": "message_start",
                "message": {"id": msg_id, "type": "message", "role": "assistant",
                            "content": [], "model": model,
                            "usage": {"input_tokens": 0, "output_tokens": 0}}
            })
            # text content block start
            yield _sse_event("content_block_start", {
                "type": "content_block_start", "index": text_idx,
                "content_block": {"type": "text", "text": ""}
            })
            yield _sse_event("ping", {"type": "ping"})

        # ── text delta ──
        text_delta = delta.get("content", "")
        if text_delta:
            yield _sse_event("content_block_delta", {
                "type": "content_block_delta", "index": text_idx,
                "delta": {"type": "text_delta", "text": text_delta}
            })

        # ── tool call deltas ──
        for tc in delta.get("tool_calls", []) or []:
            tc_index = tc.get("index", 0)
            tc_id = tc.get("id", "")
            tc_name = tc.get("function", {}).get("name", "")
            tc_args = tc.get("function", {}).get("arguments", "")

            if tc_index not in active_tool_indices:
                block_idx = tool_idx_base + len(active_tool_indices)
                active_tool_indices[tc_index] = (block_idx, tc_id, tc_name)
                yield _sse_event("content_block_start", {
                    "type": "content_block_start", "index": block_idx,
                    "content_block": {"type": "tool_use", "id": tc_id,
                                      "name": tc_name, "input": {}}
                })

            if tc_args:
                block_idx = active_tool_indices[tc_index][0]
                yield _sse_event("content_block_delta", {
                    "type": "content_block_delta", "index": block_idx,
                    "delta": {"type": "input_json_delta", "partial_json": tc_args}
                })

        # ── finish: content_block_stop + message_delta ──
        if finish_reason and delta == {}:
            # stop text block
            yield _sse_event("content_block_stop", {
                "type": "content_block_stop", "index": text_idx
            })
            # stop tool blocks
            for tc_i in sorted(active_tool_indices.keys()):
                yield _sse_event("content_block_stop", {
                    "type": "content_block_stop",
                    "index": active_tool_indices[tc_i][0]
                })
            # message_delta
            yield _sse_event("message_delta", {
                "type": "message_delta",
                "delta": {"stop_reason": FINISH_MAP.get(finish_reason, "end_turn"),
                          "stop_sequence": None},
                "usage": {"output_tokens": output_tokens or 0}
            })

    # ── message_stop (always sent at end of stream) ──
    yield _sse_event("message_stop", {"type": "message_stop"})


# ═══════════════════════════════════════════════════════════════════════
# HTTP Handlers
# ═══════════════════════════════════════════════════════════════════════

async def handle_messages(request: web.Request):
    try:
        body = await request.json()
    except json.JSONDecodeError:
        return web.json_response({
            "type": "error",
            "error": {"type": "invalid_request_error", "message": "Invalid JSON"}
        }, status=400)

    oai_body, backend = anthropic_to_openai(body)
    stream = body.get("stream", False)

    async with ClientSession(timeout=TIMEOUT) as session:
        try:
            async with session.post(f"{backend}/chat/completions", json=oai_body) as resp:
                if resp.status != 200:
                    err = await resp.text()
                    return web.json_response({
                        "type": "error",
                        "error": {"type": "api_error",
                                  "message": f"Backend {resp.status}: {err[:500]}"}
                    }, status=502)

                if stream:
                    return web.Response(
                        body=_translate_stream(resp.content, body.get("model", "")),
                        headers={"Content-Type": "text/event-stream",
                                 "Cache-Control": "no-cache",
                                 "Connection": "keep-alive"},
                    )
                return web.json_response(openai_to_anthropic(await resp.json(), body.get("model", "")))
        except asyncio.TimeoutError:
            return web.json_response({
                "type": "error",
                "error": {"type": "timeout_error", "message": "Backend timeout"}
            }, status=504)


async def handle_openai(request: web.Request):
    """Passthrough OpenAI-format requests directly to SGLang."""
    body = await request.json()
    model = body.get("model", "")
    backend = resolve_backend(model)
    stream = body.get("stream", False)

    async with ClientSession(timeout=TIMEOUT) as session:
        async with session.post(f"{backend}/chat/completions", json=body) as resp:
            if stream:
                return web.Response(
                    body=resp.content,
                    headers={"Content-Type": "text/event-stream",
                             "Cache-Control": "no-cache"},
                )
            return web.json_response(await resp.json())


async def handle_models(request: web.Request):
    # Return real model names (deduplicate by backend)
    seen = set()
    data = []
    for name, url in BACKENDS.items():
        if url not in seen:
            seen.add(url)
            data.append({"id": name, "object": "model", "created": int(time.time()),
                         "owned_by": "server-forge"})
    return web.json_response({"object": "list", "data": data})


async def handle_health(request: web.Request):
    return web.Response(text="OK")


def main():
    app = web.Application()
    app.router.add_post("/v1/messages", handle_messages)
    app.router.add_post("/v1/chat/completions", handle_openai)
    app.router.add_get("/v1/models", handle_models)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/v1/health", handle_health)

    print(f"Anthropic↔OpenAI proxy on :{PORT}")
    seen = set()
    for name, url in BACKENDS.items():
        if url not in seen:
            seen.add(url)
            print(f"  {name:35s} → {url}")
    print(f"  {'(fuzzy: 35B/A3B/MoE)':35s} → {MOE_BACKEND}")
    print(f"  {'(fuzzy: 27B/72B/32B + default)':35s} → {DEFAULT}")

    web.run_app(app, host="0.0.0.0", port=PORT)


if __name__ == "__main__":
    main()
