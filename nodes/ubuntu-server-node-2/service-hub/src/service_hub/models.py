"""Pydantic models for the Service Hub API."""

from __future__ import annotations

from typing import Any, Optional

from pydantic import BaseModel, Field


class ContainerInfo(BaseModel):
    """A Docker container occupying a GPU."""

    name: str
    image: str = ""
    model: Optional[str] = None
    port: Optional[int] = None
    status: str = "running"


class GPUStatus(BaseModel):
    """Real-time status of one GPU."""

    id: int
    name: str
    pci_slot: str = ""
    vram_total_mb: int
    vram_used_mb: int
    vram_free_mb: int
    utilization_pct: int
    temperature_c: int
    status: str = Field(description="free | in-use")
    containers: list[ContainerInfo] = Field(default_factory=list)
    assigned_profile: Optional[str] = None


class GPUListResponse(BaseModel):
    gpus: list[GPUStatus]


class GPUHistoryResponse(BaseModel):
    """{gpu_id: [{vram_pct, util_pct, ts}, ...]}"""

    history: dict[int, list[dict[str, Any]]]


class ServiceInfo(BaseModel):
    """One service declared by a profile.

    `gpu` is the placement hint the hub honours when starting the service:

    - ``"auto"``  — single-card service: pick the GPU with the most free VRAM
      at start time and export ``SERVICE_HUB_GPU=<id>`` to the serve script.
    - ``"0"`` / ``"0,1"`` — pinned device list, exported the same way.
    - ``None``    — the serve script decides (e.g. the TP=2 launcher hardcodes
      both cards); the hub passes no device env at all.

    Single-card hints (``"auto"`` or one explicit id) are user-selectable: the
    ``gpu=`` query on ``POST /api/switch/{name}`` overrides where such a
    service starts. Multi-card pins and ``None`` are not selectable.
    """

    name: str
    script: str
    args: list[str] = Field(default_factory=list)
    gpu: Optional[str] = None
    # Service port — from the profile's explicit `port:` field, else derived
    # from the health URL. Shown prominently in the UI so a started service
    # always says where it listens.
    port: Optional[int] = None
    health: Optional[str] = None
    container_prefix: Optional[str] = None
    running: bool = False
    healthy: bool = False
    # Live host GPU indices the running container was started with (from its
    # ROCR/HIP visibility env). Empty while stopped or for multi-GPU shards.
    assigned_gpus: list[int] = Field(default_factory=list)


class ProfileInfo(BaseModel):
    """Summary of a profile, for the list view."""

    name: str
    description: str = ""
    version: str = "1.0"
    gpu_count: int = 0
    roles: list[str] = Field(default_factory=list)


class ProfileDetail(BaseModel):
    """Full profile definition plus its live service state."""

    name: str
    description: str = ""
    version: str = "1.0"
    gpu_allocation: list[dict[str, Any]] = Field(default_factory=list)
    services: list[ServiceInfo] = Field(default_factory=list)
    stop_containers: list[str] = Field(default_factory=list)
    # Profiles that must be stopped before this one can start (GPU exclusivity).
    # Conflicts are treated symmetrically: a switch stops the target's listed
    # conflicts AND every profile that lists the target.
    conflicts: list[str] = Field(default_factory=list)


class ProfileListResponse(BaseModel):
    profiles: list[ProfileInfo]


class CurrentProfileResponse(BaseModel):
    # Last switched profile (may be stale — single-card profiles coexist, so
    # live truth is `active_profiles`, derived from running containers).
    profile: Optional[str] = None
    last_switch_at: Optional[str] = None
    status: str = "idle"
    active_profiles: list[str] = Field(default_factory=list)


class SwitchResult(BaseModel):
    status: str
    profile: Optional[str] = None
    stopped_containers: list[str] = Field(default_factory=list)
    started_containers: list[str] = Field(default_factory=list)
    # Where each service was placed, e.g. ["sglang-single->GPU1"]. Empty for
    # services without a device env.
    placements: list[str] = Field(default_factory=list)
    elapsed_seconds: float = 0.0
    error: Optional[str] = None


class StopResult(BaseModel):
    status: str
    stopped_containers: list[str] = Field(default_factory=list)
    elapsed_seconds: float = 0.0
    error: Optional[str] = None


class P2PStatus(BaseModel):
    """Whether dual-GPU peer-to-peer is actually available.

    Reported prominently because every multi-GPU profile on this node depends on
    it, and because it can be silently broken by a kernel or ROCm upgrade.
    """

    kernel: str
    kernel_patched: bool
    peer_access: Optional[bool] = None
    bandwidth_gbs: Optional[float] = None
    detail: str = ""