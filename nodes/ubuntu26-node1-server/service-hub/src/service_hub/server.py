"""FastAPI server for Service Hub — local service management gateway."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

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
    ProfileDetail,
    ProfileInfo,
    ProfileListResponse,
    StopResult,
    SwitchResult,
)
from .profile_executor import load_profiles, load_state, stop_all, switch_profile

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

# Paths
_HERE = Path(__file__).resolve().parent
_STATIC_DIR = _HERE.parent.parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown hooks."""
    await gpu_history.start()
    logger.info("GPU history sampling started (every 30s)")
    yield
    await gpu_history.stop()
    logger.info("Service Hub shutting down.")


app = FastAPI(
    title="Service Hub",
    description="Local service management gateway for ubuntu26-node1-server.\n\n"
    "Provides GPU status queries and one-click service profile switching.",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files (Vue build output) — must be before the catch-all "/" route
if _STATIC_DIR.is_dir():
    app.mount("/assets", StaticFiles(directory=str(_STATIC_DIR / "assets")), name="assets")

# ── Tags ──
TAG_GPU = "GPU"
TAG_PROFILE = "Profiles"
TAG_SERVICE = "Service"
TAG_CLASP = "CLASP"


# ── GET / → serve frontend ──
@app.get("/", include_in_schema=False)
async def root():
    """Serve the frontend SPA, or redirect to /docs if no build exists."""
    index = _STATIC_DIR / "index.html"
    if index.exists():
        return FileResponse(str(index))
    return HTMLResponse(
        '<html><body><p>Frontend not built. Run: <code>cd service-hub/frontend && npm run build</code></p>'
        '<p>API docs: <a href="/docs">/docs</a></p></body></html>'
    )


# ═══════════════════════════════════════════════════════════════════════
# GPU
# ═══════════════════════════════════════════════════════════════════════

@app.get("/api/gpus", response_model=GPUListResponse, tags=[TAG_GPU],
         summary="List all GPUs")
async def list_gpus():
    """Query all compute GPU cards with real-time hardware status,
    container assignments, and active profile info."""
    state = load_state()
    gpus = get_all_gpu_status(current_profile=state.get("current_profile"))
    return GPUListResponse(gpus=gpus)


@app.get("/api/gpus/{gpu_id}", response_model=GPUStatus, tags=[TAG_GPU],
         summary="Get single GPU")
async def get_gpu(gpu_id: int):
    """Query a single GPU by its index (0-3)."""
    state = load_state()
    gpus = get_all_gpu_status(current_profile=state.get("current_profile"))
    for gpu in gpus:
        if gpu.id == gpu_id:
            return gpu
    raise HTTPException(status_code=404, detail=f"GPU {gpu_id} not found")


@app.get("/api/gpu-history", response_model=GPUHistoryResponse, tags=[TAG_GPU],
         summary="GPU history (last 1 hour)")
async def get_gpu_history():
    """Return 1-hour history of VRAM% and utilization% per GPU."""
    from collections import defaultdict
    by_gpu: dict[int, list] = defaultdict(list)
    for snap in gpu_history.samples:
        for gpu_id, data in snap.items():
            by_gpu[gpu_id].append(data)
    return GPUHistoryResponse(history=by_gpu)


# ═══════════════════════════════════════════════════════════════════════
# Profiles
# ═══════════════════════════════════════════════════════════════════════

@app.get("/api/profiles", response_model=ProfileListResponse, tags=[TAG_PROFILE],
         summary="List all profiles")
async def list_profiles():
    """List all available service profiles with summary info."""
    profiles = load_profiles()
    infos = []
    for name, profile in profiles.items():
        roles = set()
        gpu_count = 0
        for alloc in profile.gpu_allocation:
            roles.add(alloc.get("role", "unknown"))
            gpu_count += len(alloc.get("gpu", []))
        infos.append(ProfileInfo(
            name=profile.name,
            description=profile.description,
            version=profile.version,
            gpu_count=gpu_count,
            roles=sorted(roles),
        ))
    return ProfileListResponse(profiles=infos)


@app.get("/api/profiles/{name}", response_model=ProfileDetail, tags=[TAG_PROFILE],
         summary="Get profile detail")
async def get_profile(name: str):
    """Get detailed GPU allocation and serve script info for a profile."""
    profiles = load_profiles()
    if name not in profiles:
        raise HTTPException(status_code=404, detail=f"Profile '{name}' not found")
    return profiles[name]


# ═══════════════════════════════════════════════════════════════════════
# Service Control
# ═══════════════════════════════════════════════════════════════════════

@app.get("/api/current", response_model=CurrentProfileResponse, tags=[TAG_SERVICE],
         summary="Get active profile")
async def get_current():
    """Get the currently active service profile."""
    state = load_state()
    return CurrentProfileResponse(
        profile=state.get("current_profile"),
        last_switch_at=state.get("last_switch_at"),
        status="active" if state.get("current_profile") else "idle",
    )


@app.post("/api/switch/{name}", response_model=SwitchResult, tags=[TAG_SERVICE],
          summary="Switch profile")
async def switch_to_profile(
    name: str,
    force: bool = Query(False, description="Force switch even if same profile"),
):
    """Switch to a named profile. Stops all managed containers first, then
    starts the new profile's services."""
    profiles = load_profiles()
    if name not in profiles:
        raise HTTPException(
            status_code=404,
            detail=f"Profile '{name}' not found. Available: {', '.join(profiles.keys())}",
        )

    logger.info("Switch request: → %s (force=%s)", name, force)
    result = await switch_profile(name, profiles, force=force)

    if result.status == "error":
        raise HTTPException(status_code=500, detail=result.error)

    return result


@app.post("/api/stop", response_model=StopResult, tags=[TAG_SERVICE],
          summary="Stop all services")
async def stop_services():
    """Stop all managed containers across all profiles."""
    logger.info("Stop request received.")
    profiles = load_profiles()
    stopped, elapsed = await stop_all(profiles)
    return StopResult(
        status="success",
        stopped_containers=stopped,
        elapsed_seconds=elapsed,
    )


@app.get("/api/history", tags=[TAG_SERVICE],
         summary="Get switch history")
async def get_history():
    """Return the profile switch history."""
    state = load_state()
    return {"history": state.get("switch_history", [])}


@app.get("/api/health", tags=[TAG_SERVICE],
         summary="Health check")
async def health():
    """Health check for the Service Hub itself."""
    return {"status": "ok", "service": "service-hub"}


# ═══════════════════════════════════════════════════════════════════════
# CLASP Proxy
# ═══════════════════════════════════════════════════════════════════════

from .profile_executor import _run as _run_cmd
from pydantic import BaseModel

CLASP_SCRIPT = Path(__file__).resolve().parent.parent.parent.parent / "serve" / "clasp-proxy.sh"


class ClaspStartRequest(BaseModel):
    """Request body for POST /clasp/start."""
    vllm_port: int = 8000
    clasp_port: int = 8080


def _get_clasp_container(clasp_port: int = 8080) -> str:
    """Get container name for a given CLASP port."""
    return f"clasp-proxy-{clasp_port}"


@app.get("/api/clasp/status", tags=[TAG_CLASP],
         summary="CLASP proxy status")
async def clasp_status(clasp_port: int = Query(8080)):
    """Check if the CLASP proxy container is running."""
    container = _get_clasp_container(clasp_port)
    rc, stdout, _ = await _run_cmd([
        "docker", "inspect", "--format", "{{.State.Status}}",
        container,
    ])
    if rc == 0 and stdout.strip() in ("running", "restarting"):
        # Also check health
        health_rc, _, _ = await _run_cmd([
            "docker", "exec", container,
            "curl", "-s", "--max-time", "3", "http://localhost:8080/health",
        ])
        return {
            "running": True,
            "healthy": health_rc == 0,
            "container": container,
            "clasp_port": clasp_port,
        }
    return {
        "running": False,
        "healthy": False,
        "container": container,
        "clasp_port": clasp_port,
    }


@app.post("/api/clasp/start", tags=[TAG_CLASP],
          summary="Start CLASP proxy")
async def clasp_start(req: ClaspStartRequest = ClaspStartRequest()):
    """Start the CLASP proxy container via the deploy script."""
    if not CLASP_SCRIPT.exists():
        raise HTTPException(status_code=500, detail=f"CLASP script not found: {CLASP_SCRIPT}")

    container = _get_clasp_container(req.clasp_port)

    # Check if already running
    rc, stdout, _ = await _run_cmd([
        "docker", "inspect", "--format", "{{.State.Status}}",
        container,
    ])
    if rc == 0 and stdout.strip() == "running":
        return {"status": "already_running", "container": container, "clasp_port": req.clasp_port}

    # Run the script with custom ports
    logger.info("Starting CLASP proxy via %s (vllm=%d, clasp=%d)", CLASP_SCRIPT, req.vllm_port, req.clasp_port)
    rc, stdout, stderr = await _run_cmd(
        ["bash", str(CLASP_SCRIPT), str(req.vllm_port), str(req.clasp_port)],
        cwd=CLASP_SCRIPT.parent.parent,
        timeout=120,
    )
    if rc != 0:
        raise HTTPException(status_code=500, detail=f"CLASP start failed: {stderr[-500:]}")

    return {"status": "started", "container": container, "clasp_port": req.clasp_port}


@app.post("/api/clasp/stop", tags=[TAG_CLASP],
          summary="Stop CLASP proxy")
async def clasp_stop(clasp_port: int = Query(8080)):
    """Stop and remove the CLASP proxy container."""
    container = _get_clasp_container(clasp_port)
    rc, stdout, _ = await _run_cmd([
        "docker", "inspect", "--format", "{{.State.Status}}",
        container,
    ])
    if rc != 0 or stdout.strip() not in ("running", "restarting", "exited"):
        return {"status": "already_stopped", "container": container, "clasp_port": clasp_port}

    rc2, _, stderr = await _run_cmd(["docker", "stop", container], timeout=30)
    if rc2 != 0:
        raise HTTPException(status_code=500, detail=f"CLASP stop failed: {stderr}")

    # Also remove the stopped container
    await _run_cmd(["docker", "rm", container], timeout=10)

    return {"status": "stopped", "container": container, "clasp_port": clasp_port}


# ═══════════════════════════════════════════════════════════════════════
# Entry point
# ═══════════════════════════════════════════════════════════════════════

def main():
    """Entry point for `uv run service-hub` or `python -m service_hub.server`."""
    import uvicorn
    uvicorn.run(
        "service_hub.server:app",
        host="0.0.0.0",
        port=9090,
        log_level="info",
    )


if __name__ == "__main__":
    main()
