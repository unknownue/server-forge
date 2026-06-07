"""GPU status monitoring via nvidia-smi and Docker inspect."""

from __future__ import annotations

import asyncio
import csv
import io
import logging
import subprocess
import time
from collections import deque
from typing import Optional

from .models import ContainerInfo, GPUStatus

logger = logging.getLogger(__name__)

# nvidia-smi query fields
SMI_FIELDS = "index,name,memory.total,memory.used,utilization.gpu,temperature.gpu"


def _run(cmd: list[str]) -> tuple[int, str, str]:
    """Run a command and return (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except FileNotFoundError:
        return -1, "", f"command not found: {cmd[0]}"


def get_nvidia_smi_status() -> dict[int, dict]:
    """Query nvidia-smi for GPU hardware status. Returns dict keyed by GPU index."""
    rc, stdout, stderr = _run([
        "nvidia-smi",
        f"--query-gpu={SMI_FIELDS}",
        "--format=csv,noheader,nounits",
    ])
    if rc != 0:
        logger.error("nvidia-smi failed: %s", stderr)
        return {}

    gpus = {}
    reader = csv.reader(io.StringIO(stdout))
    for row in reader:
        if len(row) < 6:
            continue
        try:
            idx = int(row[0].strip())
            gpus[idx] = {
                "name": row[1].strip(),
                "vram_total_mb": int(row[2].strip()),
                "vram_used_mb": int(row[3].strip()),
                "utilization_pct": int(row[4].strip()),
                "temperature_c": int(row[5].strip()),
            }
        except (ValueError, IndexError) as e:
            logger.warning("Failed to parse nvidia-smi row %s: %s", row, e)
    return gpus


def get_docker_gpu_containers() -> dict[int, list[ContainerInfo]]:
    """Find Docker containers using GPUs and map them to GPU indices.

    Returns dict: GPU index → list of ContainerInfo.
    """
    # List running containers with their env vars and labels
    rc, stdout, stderr = _run([
        "docker", "ps", "--format",
        "{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}",
    ])
    if rc != 0:
        logger.error("docker ps failed: %s", stderr)
        return {}

    gpu_containers: dict[int, list[ContainerInfo]] = {}

    for line in stdout.strip().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        name, image, ports_str, status = parts[0], parts[1], parts[2], parts[3]

        # Inspect container to get CUDA_VISIBLE_DEVICES
        rc2, stdout2, _ = _run([
            "docker", "inspect", "--format",
            "{{range .Config.Env}}{{println .}}{{end}}",
            name,
        ])
        if rc2 != 0:
            continue

        cuda_devices = None
        for env_line in stdout2.strip().splitlines():
            if env_line.startswith("CUDA_VISIBLE_DEVICES="):
                cuda_devices = env_line.split("=", 1)[1]
                break

        if cuda_devices is None:
            # Check if container has GPU access without explicit CUDA_VISIBLE_DEVICES
            # This means it sees all GPUs
            rc3, stdout3, _ = _run([
                "docker", "inspect", "--format",
                "{{.HostConfig.DeviceRequests}}",
                name,
            ])
            if rc3 == 0 and "nvidia" in stdout3.lower():
                # Container has --gpus but no CUDA_VISIBLE_DEVICES → sees all GPUs
                # We can't determine which specific GPUs it's using
                continue
            continue

        # Parse CUDA_VISIBLE_DEVICES (e.g., "0", "0,1", "0,1,2,3")
        try:
            devices = [int(d.strip()) for d in cuda_devices.split(",") if d.strip()]
        except ValueError:
            continue

        # Extract port from ports string
        port = None
        if ports_str:
            # Format: "0.0.0.0:8000->8000/tcp" or "8000/tcp"
            for p in ports_str.split(","):
                p = p.strip()
                if "->" in p:
                    host_part = p.split("->")[0].strip()
                    if ":" in host_part:
                        try:
                            port = int(host_part.rsplit(":", 1)[1])
                        except ValueError:
                            pass

        # Extract model from env (MODEL_PATH or volume mounts)
        model = None
        for env_line in stdout2.strip().splitlines():
            if env_line.startswith("MODEL_PATH="):
                model = env_line.split("=", 1)[1]
                break

        container = ContainerInfo(
            name=name,
            image=image,
            model=model,
            port=port,
            status="running" if "Up" in status else "stopped",
        )

        for gpu_id in devices:
            if gpu_id not in gpu_containers:
                gpu_containers[gpu_id] = []
            gpu_containers[gpu_id].append(container)

    return gpu_containers


def get_all_gpu_status(current_profile: Optional[str] = None) -> list[GPUStatus]:
    """Get complete status of all GPUs by combining nvidia-smi and Docker info."""
    smi_data = get_nvidia_smi_status()
    container_data = get_docker_gpu_containers()

    statuses = []
    for gpu_id in sorted(smi_data.keys()):
        smi = smi_data[gpu_id]
        containers = container_data.get(gpu_id, [])
        container = containers[0] if containers else None

        if container:
            status = "in-use"
        elif smi["vram_used_mb"] > 1000:  # >1GB used without a tracked container
            status = "in-use"
        else:
            status = "free"

        statuses.append(GPUStatus(
            id=gpu_id,
            name=smi["name"],
            vram_total_mb=smi["vram_total_mb"],
            vram_used_mb=smi["vram_used_mb"],
            vram_free_mb=smi["vram_total_mb"] - smi["vram_used_mb"],
            utilization_pct=smi["utilization_pct"],
            temperature_c=smi["temperature_c"],
            status=status,
            container=container,
            assigned_profile=current_profile if status == "in-use" else None,
        ))

    return statuses


class GPUHistory:
    """In-memory ring buffer of GPU snapshots, sampled every 30 seconds.

    Stores up to 120 samples (1 hour at 30s intervals).
    Each sample is a dict: {gpu_id: {vram_pct, util_pct, ts}}.
    """

    def __init__(self, max_samples: int = 120):
        self._buffer: deque[dict] = deque(maxlen=max_samples)
        self._task: Optional[asyncio.Task] = None

    @property
    def samples(self) -> list[dict]:
        return list(self._buffer)

    async def start(self):
        """Start the background sampling loop."""
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
                snapshot = self._snapshot()
                self._buffer.append(snapshot)
            except Exception as e:
                logger.error("GPU history sample failed: %s", e)
            await asyncio.sleep(30)

    def _snapshot(self) -> dict:
        smi = get_nvidia_smi_status()
        ts = time.time()
        result = {}
        for gpu_id, data in smi.items():
            vram_total = data["vram_total_mb"]
            vram_used = data["vram_used_mb"]
            result[gpu_id] = {
                "vram_pct": round(vram_used / vram_total * 100, 1) if vram_total > 0 else 0,
                "util_pct": data["utilization_pct"],
                "ts": ts,
            }
        return result


# Module-level singleton
gpu_history = GPUHistory()
