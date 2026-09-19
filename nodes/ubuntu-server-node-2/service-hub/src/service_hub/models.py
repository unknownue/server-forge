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
    """One service declared by a profile."""

    name: str
    script: str
    args: list[str] = Field(default_factory=list)
    health: Optional[str] = None
    container_prefix: Optional[str] = None
    running: bool = False
    healthy: bool = False


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


class ProfileListResponse(BaseModel):
    profiles: list[ProfileInfo]


class CurrentProfileResponse(BaseModel):
    profile: Optional[str] = None
    last_switch_at: Optional[str] = None
    status: str = "idle"


class SwitchResult(BaseModel):
    status: str
    profile: Optional[str] = None
    stopped_containers: list[str] = Field(default_factory=list)
    started_containers: list[str] = Field(default_factory=list)
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