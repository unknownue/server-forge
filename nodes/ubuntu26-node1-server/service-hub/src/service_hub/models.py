"""Pydantic data models for Service Hub API."""

from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class ContainerInfo(BaseModel):
    """Information about a Docker container running on a GPU."""

    name: str
    image: str
    model: Optional[str] = None
    port: Optional[int] = None
    status: str = "running"


class GPUStatus(BaseModel):
    """Status of a single GPU card."""

    id: int
    name: str
    vram_total_mb: int
    vram_used_mb: int
    vram_free_mb: int
    utilization_pct: int
    temperature_c: int
    status: str  # "in-use" | "free" | "error"
    container: Optional[ContainerInfo] = None
    assigned_profile: Optional[str] = None


class GPUListResponse(BaseModel):
    """Response for GET /gpus."""

    gpus: list[GPUStatus]


class ProfileInfo(BaseModel):
    """Summary of a profile."""

    name: str
    description: str
    version: str
    gpu_count: int
    roles: list[str]


class ProfileDetail(BaseModel):
    """Full profile information."""

    name: str
    description: str
    version: str
    gpu_allocation: list[dict]
    stop_containers: list[str]


class ProfileListResponse(BaseModel):
    """Response for GET /profiles."""

    profiles: list[ProfileInfo]


class CurrentProfileResponse(BaseModel):
    """Response for GET /current."""

    profile: Optional[str] = None
    last_switch_at: Optional[datetime] = None
    status: str = "idle"


class SwitchRequest(BaseModel):
    """Request body for POST /switch/{name}."""

    force: bool = False


class SwitchResult(BaseModel):
    """Response for POST /switch/{name}."""

    status: str  # "success" | "error"
    previous_profile: Optional[str] = None
    new_profile: str
    stopped_containers: list[str] = Field(default_factory=list)
    started_containers: list[str] = Field(default_factory=list)
    skipped_services: list[str] = Field(default_factory=list)
    elapsed_seconds: float = 0
    error: Optional[str] = None


class StopResult(BaseModel):
    """Response for POST /stop."""

    status: str
    stopped_containers: list[str] = Field(default_factory=list)
    elapsed_seconds: float = 0


class SwitchHistoryEntry(BaseModel):
    """A single switch history entry."""

    from_profile: Optional[str] = None
    to_profile: str
    at: datetime
    status: str
    elapsed_seconds: float = 0


class GPUHistorySample(BaseModel):
    """A single GPU history data point."""

    ts: float
    vram_pct: float
    util_pct: int


class GPUHistoryResponse(BaseModel):
    """Response for GET /gpu-history."""

    history: dict[int, list[GPUHistorySample]]
