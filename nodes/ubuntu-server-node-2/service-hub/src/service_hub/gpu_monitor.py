"""GPU status for AMD cards, read from sysfs.

Deliberately does NOT depend on rocm-smi / amd-smi: neither is installed on this
node (ROCm is only inside containers), and the kernel's sysfs interface exposes
everything needed here — busy %, VRAM totals, and hwmon temperatures — with no
extra packages and no privileged calls.
"""

from __future__ import annotations

import asyncio
import glob
import logging
import os
import subprocess
import time
from collections import deque
from pathlib import Path
from typing import Optional

from .models import ContainerInfo, GPUStatus

logger = logging.getLogger(__name__)

DRM_ROOT = Path("/sys/class/drm")
# AMD vendor id; used to skip non-AMD display devices.
AMD_VENDOR = "0x1002"

# Containers whose names start with these prefixes are the ones this hub manages.
MANAGED_CONTAINER_PREFIXES = ("sglang-",)


def _run(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    """Run a command and return (returncode, stdout, stderr)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except FileNotFoundError:
        return -1, "", f"command not found: {cmd[0]}"


def _read_int(path: Path) -> Optional[int]:
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def _gpu_cards() -> list[tuple[str, Path]]:
    """Return [(card_name, device_path)] for AMD GPUs, ordered by PCI slot.

    Ordering by PCI slot keeps GPU indices stable across reboots, which matters
    because profiles and ROCR_VISIBLE_DEVICES refer to indices.
    """
    cards = []
    for card in sorted(DRM_ROOT.glob("card[0-9]*")):
        # Skip connectors like card0-DP-1.
        if "-" in card.name:
            continue
        dev = card / "device"
        if not dev.exists():
            continue
        vendor = (dev / "vendor")
        try:
            if vendor.read_text().strip() != AMD_VENDOR:
                continue
        except Exception:
            continue
        cards.append((card.name, dev))

    def _slot(item: tuple[str, Path]) -> str:
        try:
            for line in (item[1] / "uevent").read_text().splitlines():
                if line.startswith("PCI_SLOT_NAME="):
                    return line.split("=", 1)[1]
        except Exception:
            pass
        return item[0]

    return sorted(cards, key=_slot)


def _temp_c(dev: Path) -> int:
    """Edge temperature in Celsius, via hwmon. 0 if unavailable."""
    for inp in sorted(glob.glob(str(dev / "hwmon" / "hwmon*" / "temp1_input"))):
        v = _read_int(Path(inp))
        if v is not None and v > 0:
            return round(v / 1000)
    return 0


def get_gpu_status(dev: Path, gpu_id: int) -> GPUStatus:
    """Read one GPU's status from sysfs."""
    total = _read_int(dev / "mem_info_vram_total") or 0
    used = _read_int(dev / "mem_info_vram_used") or 0
    busy = _read_int(dev / "gpu_busy_percent") or 0

    slot = ""
    try:
        for line in (dev / "uevent").read_text().splitlines():
            if line.startswith("PCI_SLOT_NAME="):
                slot = line.split("=", 1)[1]
    except Exception:
        pass

    mib = 1024 * 1024
    return GPUStatus(
        id=gpu_id,
        name="Radeon RX 7900 XTX",
        pci_slot=slot,
        vram_total_mb=total // mib,
        vram_used_mb=used // mib,
        vram_free_mb=max(total - used, 0) // mib,
        utilization_pct=busy,
        temperature_c=_temp_c(dev),
        status="free",
    )


def get_managed_containers() -> dict[int, list[ContainerInfo]]:
    """Map GPU index -> containers using it, from `docker ps` + inspect.

    ROCm containers select devices via ROCR_VISIBLE_DEVICES or
    HIP_VISIBLE_DEVICES (there is no --gpus equivalent without the NVIDIA
    toolkit), so both are checked.
    """
    rc, out, err = _run([
        "docker", "ps", "--format",
        "{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}",
    ])
    if rc != 0:
        logger.warning("docker ps failed: %s", err.strip())
        return {}

    result: dict[int, list[ContainerInfo]] = {}

    for line in out.strip().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        name, image, ports_str, status = parts[0], parts[1], parts[2], parts[3]

        if not name.startswith(MANAGED_CONTAINER_PREFIXES):
            continue

        rc2, env_out, _ = _run([
            "docker", "inspect", "--format",
            "{{range .Config.Env}}{{println .}}{{end}}", name,
        ])
        if rc2 != 0:
            continue

        env = {}
        for env_line in env_out.strip().splitlines():
            if "=" in env_line:
                k, v = env_line.split("=", 1)
                env[k] = v

        devices_raw = env.get("ROCR_VISIBLE_DEVICES") or env.get("HIP_VISIBLE_DEVICES")
        if devices_raw is None:
            continue
        try:
            devices = [int(d.strip()) for d in devices_raw.split(",") if d.strip()]
        except ValueError:
            continue

        port = None
        for p in ports_str.split(","):
            p = p.strip()
            if "->" in p:
                host_part = p.split("->")[0].strip()
                if ":" in host_part:
                    try:
                        port = int(host_part.rsplit(":", 1)[1])
                    except ValueError:
                        pass

        model = env.get("MODEL_PATH") or env.get("SERVED_MODEL_NAME")
        if model:
            model = os.path.basename(model.rstrip("/"))

        info = ContainerInfo(
            name=name, image=image, model=model, port=port,
            status="running" if "Up" in status else "stopped",
        )
        for gid in devices:
            result.setdefault(gid, []).append(info)

    return result


def get_all_gpu_status(current_profile: Optional[str] = None) -> list[GPUStatus]:
    """Combine sysfs hardware status with container assignments."""
    cards = _gpu_cards()
    containers = get_managed_containers()

    statuses = []
    for gpu_id, (_card, dev) in enumerate(cards):
        st = get_gpu_status(dev, gpu_id)
        st.containers = containers.get(gpu_id, [])
        # >1 GiB in use means something is resident even if we cannot attribute it.
        if st.containers or st.vram_used_mb > 1024:
            st.status = "in-use"
            st.assigned_profile = current_profile
        statuses.append(st)
    return statuses


class GPUHistory:
    """Ring buffer of GPU snapshots, sampled every 30s (1 hour of history)."""

    def __init__(self, max_samples: int = 120):
        self._buffer: deque[dict] = deque(maxlen=max_samples)
        self._task: Optional[asyncio.Task] = None

    @property
    def samples(self) -> list[dict]:
        return list(self._buffer)

    async def start(self):
        self._task = asyncio.create_task(self._loop())

    async def stop(self):
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _loop(self):
        while True:
            try:
                self._buffer.append(self._snapshot())
            except Exception as e:
                logger.error("GPU history sample failed: %s", e)
            await asyncio.sleep(30)

    def _snapshot(self) -> dict:
        ts = time.time()
        snap = {}
        for gpu_id, (_card, dev) in enumerate(_gpu_cards()):
            total = _read_int(dev / "mem_info_vram_total") or 0
            used = _read_int(dev / "mem_info_vram_used") or 0
            snap[gpu_id] = {
                "vram_pct": round(used / total * 100, 1) if total else 0.0,
                "util_pct": _read_int(dev / "gpu_busy_percent") or 0,
                "ts": ts,
            }
        return snap


gpu_history = GPUHistory()