"""Profile loading, service start/stop, and persistent state."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml

from .models import P2PStatus, ProfileDetail, ServiceInfo

logger = logging.getLogger(__name__)

# service-hub/src/service_hub/profile_executor.py -> node dir is 3 levels up.
NODE_DIR = Path(__file__).resolve().parent.parent.parent.parent
PROFILES_DIR = NODE_DIR / "profiles"
STATE_FILE = NODE_DIR / "service-hub" / ".state.json"

# Only one switch/stop may run at a time; serving takes minutes.
_lock = asyncio.Lock()


def switch_in_progress() -> bool:
    return _lock.locked()


async def _run(cmd: list[str], cwd: Optional[Path] = None, timeout: int = 300,
               env: Optional[dict[str, str]] = None) -> tuple[int, str, str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(cwd) if cwd else None,
            env={**os.environ, **env} if env else None,
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return proc.returncode or 0, out.decode(errors="replace"), err.decode(errors="replace")
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except Exception:
            pass
        return -1, "", f"timeout after {timeout}s"
    except FileNotFoundError:
        return -1, "", f"command not found: {cmd[0]}"


# ── Profiles ────────────────────────────────────────────────────────────────

def load_profiles() -> dict[str, ProfileDetail]:
    profiles: dict[str, ProfileDetail] = {}
    if not PROFILES_DIR.exists():
        logger.warning("Profiles directory not found: %s", PROFILES_DIR)
        return profiles

    for path in sorted(PROFILES_DIR.glob("*.yaml")):
        try:
            data = yaml.safe_load(path.read_text()) or {}
            if "name" not in data:
                continue
            services = [
                ServiceInfo(
                    name=s.get("name", ""),
                    script=s.get("script", ""),
                    args=[str(a) for a in s.get("args", [])],
                    health=s.get("health"),
                    container_prefix=s.get("container_prefix"),
                )
                for s in data.get("services", [])
            ]
            profiles[data["name"]] = ProfileDetail(
                name=data["name"],
                description=data.get("description", ""),
                version=str(data.get("version", "1.0")),
                gpu_allocation=data.get("gpu_allocation", []),
                services=services,
                stop_containers=data.get("stop_containers", []),
            )
        except Exception as e:
            logger.warning("Failed to load profile %s: %s", path, e)
    return profiles


# ── State ───────────────────────────────────────────────────────────────────

def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {"current_profile": None, "last_switch_at": None, "switch_history": []}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, default=str))


def _record(state: dict, profile: Optional[str], action: str, ok: bool, detail: str = "") -> None:
    state["current_profile"] = profile
    state["last_switch_at"] = datetime.now(timezone.utc).isoformat()
    state.setdefault("switch_history", []).insert(0, {
        "at": state["last_switch_at"],
        "action": action,
        "profile": profile,
        "ok": ok,
        "detail": detail[:500],
    })
    state["switch_history"] = state["switch_history"][:50]
    save_state(state)


# ── Container helpers ───────────────────────────────────────────────────────

async def stop_containers(names: list[str]) -> list[str]:
    """Force-remove the named containers. Returns those actually removed."""
    stopped = []
    for name in names:
        rc, out, _ = await _run(["docker", "ps", "-a", "-q", "--filter", f"name=^/{name}$"])
        if rc == 0 and out.strip():
            logger.info("Removing container %s", name)
            rm_rc, _, rm_err = await _run(["docker", "rm", "-f", name], timeout=60)
            if rm_rc == 0:
                stopped.append(name)
            else:
                logger.error("Failed to remove %s: %s", name, rm_err.strip())
    return stopped


async def stop_all(profiles: dict[str, ProfileDetail]) -> tuple[list[str], float, Optional[str]]:
    """Stop every container any profile manages."""
    async with _lock:
        t0 = time.perf_counter()
        names: list[str] = []
        for p in profiles.values():
            for n in p.stop_containers:
                if n not in names:
                    names.append(n)
        # Also catch anything matching a service's container_prefix, in case a
        # profile was added after a container was already running.
        rc, out, _ = await _run([
            "docker", "ps", "-a", "--format", "{{.Names}}",
        ])
        if rc == 0:
            for n in out.split():
                if n.startswith("sglang-") and n not in names:
                    names.append(n)

        try:
            stopped = await stop_containers(names)
        except Exception as e:
            return [], time.perf_counter() - t0, str(e)

        state = load_state()
        _record(state, None, "stop", True, f"stopped {len(stopped)}")
        return stopped, time.perf_counter() - t0, None


async def _container_running(prefix: str) -> bool:
    """Any container whose name starts with `prefix` and is running."""
    rc, out, _ = await _run([
        "docker", "ps", "--filter", f"name={prefix}", "--format", "{{.Names}}",
    ])
    return rc == 0 and bool(out.strip())


async def check_health(url: Optional[str], timeout: int = 3) -> bool:
    if not url:
        return False
    rc, _, _ = await _run([
        "curl", "-s", "-o", "/dev/null", "--max-time", str(timeout), url,
    ], timeout=timeout + 2)
    return rc == 0


async def populate_service_state(profile: ProfileDetail) -> ProfileDetail:
    """Fill in `running` / `healthy` for each service of a profile."""
    for svc in profile.services:
        prefix = svc.container_prefix or svc.name
        svc.running = await _container_running(prefix)
        svc.healthy = await check_health(svc.health) if svc.running else False
    return profile


# ── P2P status ──────────────────────────────────────────────────────────────

async def get_p2p_status() -> P2PStatus:
    """Report whether dual-GPU P2P is actually available.

    A lot of this node's value rides on P2P: TP=2 profiles silently fall back to
    host-staged collectives if either the patched kernel or the patched RCCL is
    missing, so surface it instead of leaving it to be discovered via slow
    throughput.
    """
    kernel = subprocess.run(["uname", "-r"], capture_output=True, text=True).stdout.strip()
    patched = kernel.endswith("-x99p2p")

    # Cheap kernel-side check: KFD exposes a GPU<->GPU link only when peer
    # access is permitted by the P2PDMA whitelist.
    peer: Optional[bool] = None
    try:
        links = list(Path("/sys/devices/virtual/kfd/kfd/topology/nodes").glob("*/p2p_links/*/properties"))
        for p in links:
            txt = p.read_text()
            if "flags 3" in txt:  # P2P_CAPABLE | P2P_DIRECT
                peer = True
                break
        if peer is None and links:
            peer = False
    except Exception as e:
        logger.debug("P2P sysfs probe failed: %s", e)

    detail = (
        "kernel is the patched *-x99p2p build" if patched
        else f"kernel {kernel} is NOT the patched build — P2P likely unavailable"
    )
    if peer is False:
        detail += "; KFD reports no GPU<->GPU peer link"
    elif peer:
        detail += "; KFD reports a direct GPU<->GPU peer link"

    return P2PStatus(kernel=kernel, kernel_patched=patched, peer_access=peer, detail=detail)


# ── Switch ──────────────────────────────────────────────────────────────────

async def switch_profile(name: str, profiles: dict[str, ProfileDetail],
                         force: bool = False) -> tuple[str, list[str], list[str], float, Optional[str]]:
    """Stop everything, then start the named profile.

    Returns (status, stopped, started, elapsed, error).
    """
    if _lock.locked():
        return "busy", [], [], 0.0, "another switch or stop is already in progress"

    async with _lock:
        profile = profiles[name]
        t0 = time.perf_counter()

        try:
            names: list[str] = []
            for p in profiles.values():
                for n in p.stop_containers:
                    if n not in names:
                        names.append(n)
            stopped = await stop_containers(names)

            started: list[str] = []
            for svc in profile.services:
                script = NODE_DIR / svc.script
                if not script.exists():
                    err = f"serve script not found: {script}"
                    _record(load_state(), name, "switch", False, err)
                    return "error", stopped, started, time.perf_counter() - t0, err

                logger.info("Starting %s: %s %s", svc.name, script, " ".join(svc.args))
                rc, out, err = await _run(
                    ["bash", str(script), *svc.args],
                    cwd=NODE_DIR, timeout=2400,
                )
                if rc != 0:
                    msg = (err or out).strip()[-500:]
                    _record(load_state(), name, "switch", False, msg)
                    return "error", stopped, started, time.perf_counter() - t0, msg
                started.append(svc.name)

            elapsed = time.perf_counter() - t0
            _record(load_state(), name, "switch", True, f"started {started}")
            return "success", stopped, started, elapsed, None

        except Exception as e:
            logger.exception("Switch failed")
            _record(load_state(), name, "switch", False, str(e))
            return "error", [], [], time.perf_counter() - t0, str(e)