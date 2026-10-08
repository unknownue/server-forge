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

from .gpu_monitor import container_visible_gpus, get_managed_containers, gpu_free_vram
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

def _norm_gpu(value) -> Optional[str]:
    """Normalize a YAML `gpu` hint to the string form exported to serve scripts.

    Accepts "auto", a bare id (0), or a list ([0, 1] -> "0,1"). None means the
    serve script keeps its own default pinning and no env is exported.
    """
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        return ",".join(str(v) for v in value)
    return str(value)


def _svc_port(s: dict, health: Optional[str]) -> Optional[int]:
    """Service port: the profile's explicit `port:` field, else the health URL.

    The health URL always targets the service's own port
    (http://localhost:8080/health_generate -> 8080), so most profiles need no
    extra field. Explicit `port:` wins when both are present.
    """
    raw = s.get("port")
    if raw is not None:
        try:
            return int(raw)
        except (TypeError, ValueError):
            logger.warning("Invalid port value in profile: %r", raw)
    if health:
        try:
            from urllib.parse import urlparse  # noqa: PLC0415

            return urlparse(health).port
        except ValueError:
            logger.warning("Invalid health URL in profile: %r", health)
    return None


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
                    gpu=_norm_gpu(s.get("gpu")),
                    port=_svc_port(s, s.get("health")),
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
                stop_containers=[str(n) for n in data.get("stop_containers", [])],
                conflicts=[str(c) for c in data.get("conflicts", [])],
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


async def _managed_names(subset: dict[str, ProfileDetail]) -> list[str]:
    """Container names managed by the given profiles.

    Exact `stop_containers` entries plus a live prefix scan against each
    service's container_prefix, so a container the static list predates (e.g.
    `sglang-tp2-gpu1` after a re-placement onto the other card) is still
    caught. Everything is derived from the profiles themselves — there is no
    hardcoded name pattern anywhere, so adding a profile is enough to put its
    containers under hub control.
    """
    names: list[str] = []
    prefixes: list[str] = []
    for p in subset.values():
        for n in p.stop_containers:
            if n not in names:
                names.append(n)
        for svc in p.services:
            prefixes.append(svc.container_prefix or svc.name)

    rc, out, _ = await _run(["docker", "ps", "-a", "--format", "{{.Names}}"])
    if rc == 0 and prefixes:
        for n in out.split():
            if n not in names and any(n.startswith(pre) for pre in prefixes):
                names.append(n)
    return names


def conflicting_profiles(name: str,
                         profiles: dict[str, ProfileDetail]) -> dict[str, ProfileDetail]:
    """The target profile plus everything that must yield its GPUs first.

    Conflicts are read symmetrically: switching to P stops the profiles P
    lists *and* the profiles that list P, so declaring the relation on either
    side (or both) is enough. P itself is included so a switch restarts it
    cleanly. Profiles with no relation to P keep running — that is what lets
    the steady state (single-card LLM + single-card ComfyUI) coexist.
    """
    target = profiles[name]
    return {
        q: p for q, p in profiles.items()
        if q == name or q in target.conflicts or name in p.conflicts
    }


async def stop_all(profiles: dict[str, ProfileDetail]) -> tuple[list[str], float, Optional[str]]:
    """Stop every container any profile manages."""
    async with _lock:
        t0 = time.perf_counter()
        try:
            stopped = await stop_containers(await _managed_names(profiles))
        except Exception as e:
            return [], time.perf_counter() - t0, str(e)

        state = load_state()
        _record(state, None, "stop", True, f"stopped {len(stopped)}")
        return stopped, time.perf_counter() - t0, None


async def stop_profile(name: str,
                       profiles: dict[str, ProfileDetail]) -> tuple[list[str], float, Optional[str]]:
    """Stop only the named profile's containers; coexisting profiles stay up.

    This is the "off" half of an independent toggle: ComfyUI can be taken down
    without touching the LLM, which `stop_all` (Stop all) would not do.
    """
    if name not in profiles:
        return [], 0.0, f"profile '{name}' not found"
    if _lock.locked():
        return [], 0.0, "another switch or stop is already in progress"

    async with _lock:
        t0 = time.perf_counter()
        try:
            stopped = await stop_containers(await _managed_names({name: profiles[name]}))
        except Exception as e:
            return [], time.perf_counter() - t0, str(e)

        state = load_state()
        _record(state, name, "stop", True, f"stopped {len(stopped)} ({name} only)")
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


async def _container_gpus(prefix: str) -> list[int]:
    """Host GPUs of the running container matching `prefix` ([] if none)."""
    rc, out, _ = await _run([
        "docker", "ps", "--filter", f"name={prefix}", "--format", "{{.Names}}",
    ])
    if rc != 0 or not out.strip():
        return []
    name = out.strip().splitlines()[0]
    # docker inspect blocks; keep it off the event loop (the UI polls this).
    return await asyncio.to_thread(container_visible_gpus, name)


async def populate_service_state(profile: ProfileDetail) -> ProfileDetail:
    """Fill in `running` / `healthy` / `assigned_gpus` for each service."""
    for svc in profile.services:
        prefix = svc.container_prefix or svc.name
        svc.running = await _container_running(prefix)
        svc.healthy = await check_health(svc.health) if svc.running else False
        svc.assigned_gpus = await _container_gpus(prefix) if svc.running else []
    return profile


async def get_active_profiles(profiles: dict[str, ProfileDetail]) -> list[str]:
    """Profiles with at least one running managed container.

    Live truth for the UI: single-card profiles coexist, so `current_profile`
    (the last switch) cannot say what is actually up.
    """
    active: list[str] = []
    for pname, p in profiles.items():
        for svc in p.services:
            if await _container_running(svc.container_prefix or svc.name):
                active.append(pname)
                break
    return active


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


# ── Placement ───────────────────────────────────────────────────────────────

def _single_card_hint(svc: ServiceInfo) -> Optional[str]:
    """"auto" or the pinned id for a one-device service, else None.

    A service is GPU-selectable when its `gpu` hint names exactly one device:
    "auto" (placement decides) or a single explicit id ("0"). Multi-card pins
    ("0,1") and services without a hint pin their own devices and cannot be
    chosen through the API.
    """
    if svc.gpu is None:
        return None
    if svc.gpu.strip().lower() == "auto":
        return "auto"
    ids = [x for x in svc.gpu.split(",") if x.strip()]
    return svc.gpu.strip() if len(ids) == 1 else None


def _placement_env(svc: ServiceInfo, reserved: set[int],
                   pin: Optional[int] = None) -> tuple[dict[str, str], Optional[str]]:
    """Device env for one service start: (env, error).

    Single-card `auto` services go to the GPU with the most free VRAM among
    those not already reserved by an earlier service of the same start.
    Services are launched sequentially and model loading takes minutes, so
    re-reading free VRAM between starts would not reflect the previous pick —
    the reservation set is what keeps two single-card services apart.

    `pin` is the user's explicit GPU choice (the API's `?gpu=` override) and
    wins over both `auto` and a profile-level pin for single-card services.
    Explicit profile pins ("0", "0,1") are honored and reserved the same way
    when no pin is given. A service without a `gpu` hint gets no env at all:
    the serve script keeps its own pinning (the TP=2 launcher hardcodes both
    cards).
    """
    if svc.gpu is None:
        return {}, None

    is_auto = svc.gpu.strip().lower() == "auto"
    if is_auto:
        ids: list[int] = []
    else:
        try:
            ids = [int(x) for x in svc.gpu.split(",") if x.strip()]
        except ValueError:
            return {}, f"service '{svc.name}' has an invalid gpu hint: {svc.gpu!r}"

    if pin is not None:
        if not is_auto and len(ids) != 1:
            return {}, (f"service '{svc.name}' spans multiple GPUs ({svc.gpu}); "
                        f"a single-card GPU choice does not apply")
        ids = [pin]
        is_auto = False

    if is_auto:
        free = gpu_free_vram()
        order = sorted((g for g in free if g not in reserved),
                       key=lambda g: (-free[g], g))
        if not order:
            return {}, (f"no free GPU for service '{svc.name}' "
                        f"(reserved already: {sorted(reserved) or 'none'})")
        pick = order[0]
        reserved.add(pick)
        logger.info("Placement: %s -> GPU %d (free MB: %s)", svc.name, pick,
                    {g: free[g] for g in sorted(free)})
        return {"SERVICE_HUB_GPU": str(pick)}, None

    overlap = sorted(reserved & set(ids))
    if overlap:
        return {}, (f"GPU {overlap} already assigned to an earlier service "
                    f"of profile start")
    reserved.update(ids)
    logger.info("Placement: %s -> GPU %s%s", svc.name, ",".join(str(i) for i in ids),
                " (user-selected)" if pin is not None else "")
    return {"SERVICE_HUB_GPU": ",".join(str(i) for i in ids)}, None


def _resolve_gpu_choice(gpu: Optional[str],
                        profile: ProfileDetail) -> tuple[Optional[dict[str, int]], Optional[str]]:
    """Parse the API's `?gpu=` override into per-service pins: (pins, error).

    `pins` maps service name -> GPU id, covering every single-card service of
    the profile in service order. None means "no override": auto placement and
    profile pins apply as written. All validation happens here — before
    anything is stopped — so a bad request can never take a running service
    down first.
    """
    if gpu is None or not gpu.strip() or gpu.strip().lower() == "auto":
        return None, None

    selectable = [svc for svc in profile.services if _single_card_hint(svc) is not None]
    try:
        ids = [int(x) for x in gpu.split(",") if x.strip()]
    except ValueError:
        ids = []
    if not ids:
        return None, (f"invalid gpu value {gpu!r}: expected a GPU id (e.g. gpu=1) "
                      f"or a comma list (e.g. gpu=1,0)")
    if len(ids) != len(selectable):
        names = ", ".join(s.name for s in selectable) or "none"
        return None, (f"gpu={gpu} provides {len(ids)} id(s) but profile '{profile.name}' "
                      f"has {len(selectable)} single-card service(s) ({names})")
    known = sorted(gpu_free_vram())
    unknown = [i for i in ids if i not in known]
    if unknown:
        return None, f"unknown GPU id(s) {unknown}; this node has GPU(s) {known}"
    if len(set(ids)) != len(ids):
        return None, f"duplicate GPU ids in gpu={gpu}"
    return {svc.name: gid for svc, gid in zip(selectable, ids)}, None


async def _occupants_on(gpu_ids: list[int]) -> dict[int, list[str]]:
    """{gpu_id: [container names]} of running managed containers on the GPUs.

    Used to refuse a user-picked card that a coexisting profile is already
    using: two model servers on one 24 GB card OOM each other silently. The
    profile's own containers are gone by the time this runs (its restart stops
    them first), so a restart onto the same or another card is never blocked.
    """
    managed = await asyncio.to_thread(get_managed_containers)
    out: dict[int, list[str]] = {}
    for gid in gpu_ids:
        names = [c.name for c in managed.get(gid, [])]
        if names:
            out[gid] = names
    return out


# ── Switch ──────────────────────────────────────────────────────────────────

async def switch_profile(name: str, profiles: dict[str, ProfileDetail],
                         force: bool = False,
                         gpu: Optional[str] = None,
                         ) -> tuple[str, list[str], list[str], list[str], float, Optional[str]]:
    """Start the named profile, stopping only what conflicts with it.

    Returns (status, stopped, started, placements, elapsed, error).

    Conflict-aware rather than "stop the world": profiles with no GPU
    conflict keep running, which is what makes the steady state (single-card
    LLM + single-card ComfyUI) composable. `stop_all` remains the nuclear
    option. Single-card services are placed on the freest GPU and started
    one after another.

    `gpu` is the user's card choice ("1", or "1,0" for profiles with several
    single-card services in service order); it overrides auto placement and
    profile pins for those services. An explicit pick on a card a coexisting
    profile is using is refused unless `force` — two model servers on one card
    OOM each other. `force` skips only that occupancy check.
    """
    if _lock.locked():
        return "busy", [], [], [], 0.0, "another switch or stop is already in progress"

    pins, perr = _resolve_gpu_choice(gpu, profiles[name])
    if perr:
        return "invalid", [], [], [], 0.0, perr

    async with _lock:
        profile = profiles[name]
        t0 = time.perf_counter()

        try:
            subset = conflicting_profiles(name, profiles)
            stopped = await stop_containers(await _managed_names(subset))

            # User-picked cards must be checked AFTER the conflicts above are
            # gone: a container this switch removes (its own restart, or a
            # conflicting profile) does not count as an occupant. What remains
            # is a coexisting profile, and sharing one 24 GB card OOMs both.
            if pins and not force:
                occupants = await _occupants_on(sorted(set(pins.values())))
                if occupants:
                    detail = "; ".join(
                        f"GPU {g}: {', '.join(ns)}" for g, ns in sorted(occupants.items()))
                    err = (f"requested GPU is busy: {detail}. Stop that profile first, "
                           f"pick another card, or retry with force=true")
                    _record(load_state(), name, "switch", False, err)
                    return "conflict", stopped, [], [], time.perf_counter() - t0, err

            started: list[str] = []
            placements: list[str] = []
            reserved: set[int] = set()
            for svc in profile.services:
                script = NODE_DIR / svc.script
                if not script.exists():
                    err = f"serve script not found: {script}"
                    _record(load_state(), name, "switch", False, err)
                    return "error", stopped, started, placements, time.perf_counter() - t0, err

                env, perr = _placement_env(svc, reserved,
                                           pin=pins.get(svc.name) if pins else None)
                if perr:
                    _record(load_state(), name, "switch", False, perr)
                    return "error", stopped, started, placements, time.perf_counter() - t0, perr

                logger.info("Starting %s: %s %s%s", svc.name, script,
                            " ".join(svc.args),
                            f" [GPU {env['SERVICE_HUB_GPU']}]" if env else "")
                rc, out, err = await _run(
                    ["bash", str(script), *svc.args],
                    cwd=NODE_DIR, timeout=2400, env=env or None,
                )
                if rc != 0:
                    msg = (err or out).strip()[-500:]
                    _record(load_state(), name, "switch", False, msg)
                    return "error", stopped, started, placements, time.perf_counter() - t0, msg
                started.append(svc.name)
                if "SERVICE_HUB_GPU" in env:
                    placements.append(f"{svc.name}->GPU{env['SERVICE_HUB_GPU']}")

            elapsed = time.perf_counter() - t0
            detail = f"started {started}"
            if placements:
                detail += f", placement: {', '.join(placements)}"
            _record(load_state(), name, "switch", True, detail)
            return "success", stopped, started, placements, elapsed, None

        except Exception as e:
            logger.exception("Switch failed")
            _record(load_state(), name, "switch", False, str(e))
            return "error", [], [], [], time.perf_counter() - t0, str(e)