"""FastAPI server for the ubuntu-server-node-2 Service Hub.

Local gateway for a dual AMD RX 7900 XTX node: reports GPU status and starts /
stops serving profiles with one click.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

from .gpu_monitor import get_all_gpu_status, gpu_history
from .models import (
    CurrentProfileResponse,
    GPUHistoryResponse,
    GPUListResponse,
    GPUStatus,
    P2PStatus,
    ProfileDetail,
    ProfileInfo,
    ProfileListResponse,
    StopResult,
    SwitchResult,
)
from .profile_executor import (
    get_active_profiles,
    get_p2p_status,
    load_profiles,
    load_state,
    populate_service_state,
    stop_all,
    stop_profile,
    switch_in_progress,
    switch_profile,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

_HERE = Path(__file__).resolve().parent
_STATIC_DIR = _HERE.parent.parent / "static"

TAG_GPU = "GPU"
TAG_PROFILE = "Profiles"
TAG_SERVICE = "Service"


@asynccontextmanager
async def lifespan(app: FastAPI):
    await gpu_history.start()
    logger.info("GPU history sampling started (every 30s)")
    yield
    await gpu_history.stop()
    logger.info("Service Hub shutting down.")


app = FastAPI(
    title="Service Hub — ubuntu-server-node-2",
    description=(
        "Local service management gateway for a dual AMD RX 7900 XTX node.\n\n"
        "Reports GPU status (via sysfs, no ROCm tools required) and starts or "
        "stops serving profiles."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount the built frontend, if present. Guarded because StaticFiles raises when
# the directory is missing, which would stop the API from starting before the
# frontend has ever been built.
if (_STATIC_DIR / "assets").is_dir():
    app.mount("/assets", StaticFiles(directory=str(_STATIC_DIR / "assets")), name="assets")


@app.get("/", include_in_schema=False)
async def root():
    index = _STATIC_DIR / "index.html"
    if index.exists():
        return FileResponse(str(index))
    return HTMLResponse(
        "<html><body><p>Frontend not built. Run: "
        "<code>cd service-hub/frontend &amp;&amp; npm install &amp;&amp; npm run build</code></p>"
        '<p>API docs: <a href="/docs">/docs</a></p></body></html>'
    )


# ═══════════════════════════════════════════════════════════════════════
# GPU
# ═══════════════════════════════════════════════════════════════════════

@app.get("/api/gpus", response_model=GPUListResponse, tags=[TAG_GPU], summary="List all GPUs")
async def list_gpus():
    """All AMD GPUs with live VRAM, utilization, temperature and container use."""
    state = load_state()
    return GPUListResponse(gpus=get_all_gpu_status(current_profile=state.get("current_profile")))


@app.get("/api/gpus/{gpu_id}", response_model=GPUStatus, tags=[TAG_GPU], summary="Get single GPU")
async def get_gpu(gpu_id: int):
    state = load_state()
    for gpu in get_all_gpu_status(current_profile=state.get("current_profile")):
        if gpu.id == gpu_id:
            return gpu
    raise HTTPException(status_code=404, detail=f"GPU {gpu_id} not found")


@app.get("/api/gpu-history", response_model=GPUHistoryResponse, tags=[TAG_GPU],
         summary="GPU history (last hour)")
async def get_gpu_history():
    from collections import defaultdict
    by_gpu: dict[int, list] = defaultdict(list)
    for snap in gpu_history.samples:
        for gpu_id, data in snap.items():
            by_gpu[gpu_id].append(data)
    return GPUHistoryResponse(history=by_gpu)


@app.get("/api/p2p", response_model=P2PStatus, tags=[TAG_GPU], summary="Dual-GPU P2P status")
async def p2p_status():
    """Whether cross-GPU peer access is available.

    Multi-GPU profiles depend on this; it can be silently lost after a kernel or
    ROCm upgrade, which shows up only as unexpectedly slow generation.
    """
    return await get_p2p_status()


# ═══════════════════════════════════════════════════════════════════════
# Profiles
# ═══════════════════════════════════════════════════════════════════════

def _alloc_gpu_count(alloc: dict) -> int:
    """GPUs an allocation entry claims — `gpu` may be a list or the string "auto"."""
    gpu = alloc.get("gpu", [])
    if isinstance(gpu, str):
        return 1 if gpu.lower() == "auto" else len([x for x in gpu.split(",") if x])
    if isinstance(gpu, list):
        return len(gpu)
    return 0


@app.get("/api/profiles", response_model=ProfileListResponse, tags=[TAG_PROFILE],
         summary="List all profiles")
async def list_profiles():
    infos = []
    for name, p in load_profiles().items():
        roles, gpu_count = set(), 0
        for alloc in p.gpu_allocation:
            roles.add(alloc.get("role", "unknown"))
            gpu_count += _alloc_gpu_count(alloc)
        infos.append(ProfileInfo(
            name=p.name, description=p.description, version=p.version,
            gpu_count=gpu_count, roles=sorted(roles),
        ))
    return ProfileListResponse(profiles=infos)


@app.get("/api/profiles/{name}", response_model=ProfileDetail, tags=[TAG_PROFILE],
         summary="Get profile detail")
async def get_profile(name: str):
    profiles = load_profiles()
    if name not in profiles:
        raise HTTPException(status_code=404, detail=f"Profile '{name}' not found")
    return await populate_service_state(profiles[name])


# ═══════════════════════════════════════════════════════════════════════
# Service control
# ═══════════════════════════════════════════════════════════════════════

@app.get("/api/current", response_model=CurrentProfileResponse, tags=[TAG_SERVICE],
         summary="Get active profile")
async def get_current():
    state = load_state()
    active = await get_active_profiles(load_profiles())
    return CurrentProfileResponse(
        profile=state.get("current_profile"),
        last_switch_at=state.get("last_switch_at"),
        status="active" if active else "idle",
        active_profiles=active,
    )


@app.get("/api/history", tags=[TAG_SERVICE], summary="Get switch history")
async def get_history():
    return {"history": load_state().get("switch_history", [])}


@app.post("/api/switch/{name}", response_model=SwitchResult, tags=[TAG_SERVICE],
          summary="Switch profile")
async def switch_to(name: str, force: bool = Query(False),
                    gpu: Optional[str] = Query(None)):
    """Start the named profile, stopping only what conflicts with it.

    Blocking: serving takes a minute or more to become healthy, and the request
    returns only once the profile's services have been launched.

    Conflict-aware: coexisting profiles (no GPU conflict declared between them)
    keep running, so single-card services compose. Single-card services are
    placed on the freest GPU and launched sequentially. Use `/api/stop` to stop
    everything regardless of conflicts.

    `gpu` picks the card for the profile's single-card services ("auto"/omitted
    = freest GPU; "1" = GPU 1; "1,0" = one id per single-card service, in
    service order). A pick on a card a coexisting profile already uses is
    refused with 409 unless `force=true`. Only services whose profile `gpu`
    hint is `auto` or a single id are selectable.
    """
    profiles = load_profiles()
    if name not in profiles:
        raise HTTPException(
            status_code=404,
            detail=f"Profile '{name}' not found. Available: {', '.join(profiles)}",
        )
    if switch_in_progress():
        raise HTTPException(status_code=409,
                            detail="Another switch or stop is already in progress.")

    logger.info("Switch request -> %s (force=%s, gpu=%s)", name, force, gpu)
    status, stopped, started, placements, elapsed, error = await switch_profile(
        name, profiles, force=force, gpu=gpu)
    if status == "error":
        raise HTTPException(status_code=500, detail=error)
    if status == "invalid":
        raise HTTPException(status_code=400, detail=error)
    if status == "conflict":
        raise HTTPException(status_code=409, detail=error)
    return SwitchResult(
        status=status, profile=name, stopped_containers=stopped,
        started_containers=started, placements=placements,
        elapsed_seconds=round(elapsed, 1),
    )


@app.post("/api/stop", response_model=StopResult, tags=[TAG_SERVICE],
          summary="Stop all services")
async def stop_services():
    stopped, elapsed, error = await stop_all(load_profiles())
    if error:
        return StopResult(status="error", stopped_containers=[], elapsed_seconds=elapsed, error=error)
    return StopResult(status="success", stopped_containers=stopped,
                      elapsed_seconds=round(elapsed, 1))


@app.post("/api/profiles/{name}/stop", response_model=StopResult, tags=[TAG_SERVICE],
          summary="Stop one profile")
async def stop_one(name: str):
    """Stop only this profile's containers — coexisting profiles keep running.

    The "off" half of an independent toggle (e.g. take ComfyUI down without
    touching the single-card LLM). `/api/stop` remains the stop-everything.
    """
    profiles = load_profiles()
    if name not in profiles:
        raise HTTPException(
            status_code=404,
            detail=f"Profile '{name}' not found. Available: {', '.join(profiles)}",
        )
    if switch_in_progress():
        raise HTTPException(status_code=409,
                            detail="Another switch or stop is already in progress.")

    stopped, elapsed, error = await stop_profile(name, profiles)
    if error:
        raise HTTPException(status_code=500, detail=error)
    return StopResult(status="success", stopped_containers=stopped,
                      elapsed_seconds=round(elapsed, 1))


@app.get("/api/health", tags=[TAG_SERVICE], summary="Health check")
async def health():
    return {"status": "ok", "service": "service-hub"}


def main():
    import uvicorn
    uvicorn.run("service_hub.server:app", host="0.0.0.0", port=9090, log_level="info")


if __name__ == "__main__":
    main()