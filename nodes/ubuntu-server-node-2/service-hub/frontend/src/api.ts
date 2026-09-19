// Typed API client for the Service Hub backend.

export interface ContainerInfo {
  name: string
  image: string
  model: string | null
  port: number | null
  status: string
}

export interface GPUStatus {
  id: number
  name: string
  pci_slot: string
  vram_total_mb: number
  vram_used_mb: number
  vram_free_mb: number
  utilization_pct: number
  temperature_c: number
  status: 'free' | 'in-use'
  containers: ContainerInfo[]
  assigned_profile: string | null
}

export interface P2PStatus {
  kernel: string
  kernel_patched: boolean
  peer_access: boolean | null
  bandwidth_gbs: number | null
  detail: string
}

export interface ServiceInfo {
  name: string
  script: string
  args: string[]
  health: string | null
  container_prefix: string | null
  running: boolean
  healthy: boolean
}

export interface ProfileInfo {
  name: string
  description: string
  version: string
  gpu_count: number
  roles: string[]
}

export interface ProfileDetail {
  name: string
  description: string
  version: string
  gpu_allocation: Array<Record<string, any>>
  services: ServiceInfo[]
  stop_containers: string[]
}

export interface CurrentProfile {
  profile: string | null
  last_switch_at: string | null
  status: string
}

export interface SwitchResult {
  status: string
  profile: string | null
  stopped_containers: string[]
  started_containers: string[]
  elapsed_seconds: number
  error: string | null
}

export interface StopResult {
  status: string
  stopped_containers: string[]
  elapsed_seconds: number
  error: string | null
}

export interface GPUHistory {
  history: Record<string, Array<{ vram_pct: number; util_pct: number; ts: number }>>
}

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(path, init)
  if (!r.ok) {
    // Surface the backend's detail message rather than a bare status code.
    let detail = `${r.status} ${r.statusText}`
    try {
      const body = await r.json()
      if (body?.detail) detail = body.detail
    } catch { /* keep the status line */ }
    throw new Error(detail)
  }
  return r.json() as Promise<T>
}

export const api = {
  gpus: () => req<{ gpus: GPUStatus[] }>('/api/gpus'),
  gpuHistory: () => req<GPUHistory>('/api/gpu-history'),
  p2p: () => req<P2PStatus>('/api/p2p'),
  profiles: () => req<{ profiles: ProfileInfo[] }>('/api/profiles'),
  profile: (name: string) => req<ProfileDetail>(`/api/profiles/${encodeURIComponent(name)}`),
  current: () => req<CurrentProfile>('/api/current'),
  history: () => req<{ history: any[] }>('/api/history'),
  switch: (name: string) =>
    req<SwitchResult>(`/api/switch/${encodeURIComponent(name)}`, { method: 'POST' }),
  stop: () => req<StopResult>('/api/stop', { method: 'POST' }),
  health: () => req<{ status: string }>('/api/health'),
}