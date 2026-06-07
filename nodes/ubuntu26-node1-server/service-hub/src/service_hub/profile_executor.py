"""Profile executor — stop current services and start new profile."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml

from .models import ProfileDetail, SwitchResult

logger = logging.getLogger(__name__)

# Resolve the node directory (parent of service-hub/)
NODE_DIR = Path(__file__).resolve().parent.parent.parent.parent
PROFILES_DIR = NODE_DIR / "profiles"
STATE_FILE = NODE_DIR / "service-hub" / ".state.json"


async def _run(cmd: list[str], cwd: Optional[Path] = None, timeout: int = 300,
               env: Optional[dict[str, str]] = None) -> tuple[int, str, str]:
    """Run a command asynchronously and return (returncode, stdout, stderr)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(cwd) if cwd else None,
            env={**os.environ, **env} if env else None,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return proc.returncode or 0, stdout.decode(errors="replace"), stderr.decode(errors="replace")
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except Exception:
            pass
        return -1, "", "timeout"
    except FileNotFoundError:
        return -1, "", f"command not found: {cmd[0]}"


def load_profiles() -> dict[str, ProfileDetail]:
    """Load all profile YAML files from the profiles directory."""
    profiles = {}
    if not PROFILES_DIR.exists():
        logger.warning("Profiles directory not found: %s", PROFILES_DIR)
        return profiles

    for path in sorted(PROFILES_DIR.glob("*.yaml")):
        try:
            with open(path) as f:
                data = yaml.safe_load(f)
            if data and "name" in data:
                profiles[data["name"]] = ProfileDetail(
                    name=data["name"],
                    description=data.get("description", ""),
                    version=data.get("version", "1.0"),
                    gpu_allocation=data.get("gpu_allocation", []),
                    stop_containers=data.get("stop_containers", []),
                )
        except Exception as e:
            logger.warning("Failed to load profile %s: %s", path, e)
    return profiles


def load_state() -> dict:
    """Load persistent state from .state.json."""
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "current_profile": None,
        "last_switch_at": None,
        "switch_history": [],
    }


def save_state(state: dict) -> None:
    """Save persistent state to .state.json."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2, default=str)


async def stop_containers(container_names: list[str]) -> list[str]:
    """Stop and remove Docker containers by name. Returns list of actually stopped names."""
    stopped = []
    for name in container_names:
        rc, stdout, _ = await _run(["docker", "ps", "-a", "-q", "--filter", f"name=^/{name}$"])
        if rc == 0 and stdout.strip():
            logger.info("Stopping container: %s", name)
            rm_rc, _, rm_stderr = await _run(["docker", "rm", "-f", name])
            if rm_rc == 0:
                stopped.append(name)
            else:
                logger.error("Failed to stop container %s: %s", name, rm_stderr.strip())
        else:
            logger.debug("Container not found (already stopped): %s", name)
    return stopped


async def start_profile_services(profile: ProfileDetail) -> tuple[list[str], list[str]]:
    """Start services defined in a profile.

    Returns (started_containers, skipped_services).
    """
    started = []
    skipped = []

    for alloc in profile.gpu_allocation:
        serve = alloc.get("serve", {})
        if not serve or serve.get("skip"):
            skipped.append(alloc.get("name", alloc.get("model", "unknown")))
            continue

        script = serve.get("script")
        if not script:
            logger.warning("No serve script for %s", alloc.get("model", "unknown"))
            continue

        script_path = NODE_DIR / script
        if not script_path.exists():
            logger.error("Serve script not found: %s", script_path)
            continue

        args = serve.get("args", [])
        cmd = ["bash", str(script_path)] + [str(a) for a in args]

        # Pass container_name so the serve script uses our name (matches stop_containers)
        serve_env = {}
        container_name = alloc.get("container_name")
        if container_name:
            serve_env["SERVICE_HUB_CONTAINER_NAME"] = container_name

        logger.info("Starting service: %s %s", script, " ".join(str(a) for a in args))
        rc, stdout, stderr = await _run(cmd, cwd=NODE_DIR, timeout=600, env=serve_env)

        if rc != 0:
            logger.error("Failed to start %s: %s", script, stderr[-500:] if stderr else "")
        else:
            if container_name:
                started.append(container_name)
            logger.info("Service started: %s", script)

    return started, skipped


async def switch_profile(name: str, profiles: dict[str, ProfileDetail], force: bool = False) -> SwitchResult:
    """Switch to a named profile: stop old services, start new ones."""
    start_time = time.time()

    if name not in profiles:
        return SwitchResult(
            status="error",
            new_profile=name,
            error=f"Profile '{name}' not found. Available: {', '.join(profiles.keys())}",
        )

    state = load_state()
    current = state.get("current_profile")
    target = profiles[name]

    # If same profile and not forcing, skip
    if current == name and not force:
        return SwitchResult(
            status="success",
            previous_profile=current,
            new_profile=name,
            elapsed_seconds=0,
        )

    all_stopped = []
    all_started = []
    all_skipped = []

    # Step 1: Stop ALL containers from ALL profiles (clean slate)
    logger.info("Stopping all managed containers...")
    all_container_names = set()
    for p in profiles.values():
        all_container_names.update(p.stop_containers)

    stopped = await stop_containers(list(all_container_names))
    all_stopped.extend(stopped)

    # Wait for containers to fully exit
    if stopped:
        await asyncio.sleep(2)

    # Step 2: Start new profile services
    logger.info("Starting profile: %s", name)
    started, skipped = await start_profile_services(target)
    all_started.extend(started)
    all_skipped.extend(skipped)

    # Step 3: Update state
    elapsed = time.time() - start_time
    state["current_profile"] = name
    state["last_switch_at"] = datetime.now(timezone.utc).isoformat()
    history = state.get("switch_history", [])
    history.append({
        "from_profile": current,
        "to_profile": name,
        "at": state["last_switch_at"],
        "status": "success",
        "elapsed_seconds": round(elapsed, 1),
    })
    state["switch_history"] = history[-50:]
    save_state(state)

    return SwitchResult(
        status="success",
        previous_profile=current,
        new_profile=name,
        stopped_containers=all_stopped,
        started_containers=all_started,
        skipped_services=all_skipped,
        elapsed_seconds=round(elapsed, 1),
    )


async def stop_all(profiles: dict[str, ProfileDetail]) -> tuple[list[str], float]:
    """Stop all managed containers. Returns (stopped_names, elapsed_seconds)."""
    start_time = time.time()

    all_container_names = set()
    for p in profiles.values():
        all_container_names.update(p.stop_containers)

    stopped = await stop_containers(list(all_container_names))
    elapsed = time.time() - start_time

    state = load_state()
    state["current_profile"] = None
    state["last_switch_at"] = datetime.now(timezone.utc).isoformat()
    save_state(state)

    return stopped, round(elapsed, 1)
