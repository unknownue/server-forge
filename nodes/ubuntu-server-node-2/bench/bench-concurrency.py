#!/usr/bin/env python3
"""Concurrency benchmark for an OpenAI-compatible endpoint.

Self-contained (stdlib only) so it can run inside the SGLang image that is
already on this node, with no extra install step.

Measures, per request: TTFT, decode rate, and end-to-end latency; then reports
aggregate output throughput at each concurrency level. Uses non-streaming
ordering internally but streams, because TTFT is otherwise unavailable.

Env:
  BASE_URL     default http://localhost:8080/v1
  MODEL        served model name
  CONC         comma-separated concurrency levels (default 1,2,4)
  MAX_TOKENS   output tokens per request (default 256)
  REQUESTS     requests per level (default 4 x concurrency)
  PROMPT       prompt text

Usage:
  python3 bench/bench-concurrency.py
"""

from __future__ import annotations

import json
import os
import statistics
import threading
import time
import urllib.request
from typing import Optional

BASE = os.environ.get("BASE_URL", "http://localhost:8080/v1")
MODEL = os.environ.get("MODEL", "Qwen3.8-27B-W4A16-AutoRound-GPTQ")
LEVELS = [int(x) for x in os.environ.get("CONC", "1,2,4").split(",")]
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))
PROMPT = os.environ.get(
    "PROMPT",
    "Write a detailed technical explanation of GPU memory hierarchies, "
    "covering registers, shared memory, L2, and HBM.",
)


def one_request(ignore_eos: bool = True) -> dict:
    """Stream one completion; return its timing breakdown."""
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": MAX_TOKENS,
        "temperature": 0.0,
        "stream": True,
        "ignore_eos": ignore_eos,
    }).encode()

    req = urllib.request.Request(
        f"{BASE}/chat/completions", data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft: Optional[float] = None
    n = 0
    try:
        with urllib.request.urlopen(req, timeout=1200) as r:
            for line in r:
                if not line.startswith(b"data: "):
                    continue
                payload = line[6:].strip()
                if payload == b"[DONE]":
                    break
                try:
                    d = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                delta = d.get("choices", [{}])[0].get("delta", {})
                # Count every generated chunk, not just `content`: this model
                # emits a `reasoning_content` thinking channel, and the final
                # chunk often carries reasoning only. Counting `content` alone
                # undercounts output by ~40% and understates throughput.
                if delta.get("content") or delta.get("reasoning_content"):
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    n += 1
    except Exception as e:
        return {"error": str(e)}
    total = time.perf_counter() - t0
    return {"ttft": ttft, "tokens": n, "total": total}


def run_level(conc: int, requests: int) -> dict:
    """Fire `requests` requests with `conc` in flight; one shared wall clock."""
    results: list[dict] = [{} for _ in range(requests)]
    lock = threading.Lock()
    nxt = [0]

    def worker():
        while True:
            with lock:
                i = nxt[0]
                if i >= requests:
                    return
                nxt[0] = i + 1
            results[i] = one_request()

    t0 = time.perf_counter()
    threads = [threading.Thread(target=worker) for _ in range(conc)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0

    ok = [r for r in results if r.get("tokens")]
    if not ok:
        errs = {r.get("error", "unknown") for r in results}
        return {"conc": conc, "error": "; ".join(list(errs)[:2])}

    total_tokens = sum(r["tokens"] for r in ok)
    ttfts = [r["ttft"] for r in ok if r["ttft"] is not None]
    # Per-request decode rate, excluding its own TTFT.
    rates = [r["tokens"] / max(r["total"] - (r["ttft"] or 0), 1e-9) for r in ok]

    return {
        "conc": conc,
        "requests": len(ok),
        "wall_s": wall,
        "output_tokens": total_tokens,
        # Aggregate throughput: what the server produced per wall-clock second
        # across all concurrent streams. This is the number the source thread
        # quotes (147.5 tok/s at c=4).
        "aggregate_tok_s": total_tokens / wall,
        "per_stream_tok_s": statistics.mean(rates),
        "ttft_p50": statistics.median(ttfts) if ttfts else None,
        "ttft_max": max(ttfts) if ttfts else None,
    }


def main():
    print(f"endpoint : {BASE}")
    print(f"model    : {MODEL}")
    print(f"tokens   : {MAX_TOKENS} per request")
    print()
    print(f"{'conc':>4} {'reqs':>5} {'wall':>7} {'agg tok/s':>10} "
          f"{'per-stream':>11} {'TTFT p50':>9} {'TTFT max':>9}")
    print("-" * 62)

    out = []
    for c in LEVELS:
        requests = max(c * 4, 4)
        r = run_level(c, requests)
        out.append(r)
        if "error" in r:
            print(f"{c:>4}  ERROR: {r['error']}")
            continue
        ttft_p50 = f"{r['ttft_p50']:.2f}s" if r["ttft_p50"] else "n/a"
        ttft_max = f"{r['ttft_max']:.2f}s" if r["ttft_max"] else "n/a"
        print(f"{r['conc']:>4} {r['requests']:>5} {r['wall_s']:>6.1f}s "
              f"{r['aggregate_tok_s']:>10.1f} {r['per_stream_tok_s']:>11.1f} "
              f"{ttft_p50:>9} {ttft_max:>9}")
    print()
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()