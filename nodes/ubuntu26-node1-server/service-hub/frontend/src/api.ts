const BASE = '/api'

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
  vram_total_mb: number
  vram_used_mb: number
  vram_free_mb: number
  utilization_pct: number
  temperature_c: number
  status: string
  container: ContainerInfo | null
  assigned_profile: string | null
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
  gpu_allocation: Record<string, any>[]
  stop_containers: string[]
}

export interface CurrentProfile {
  profile: string | null
  last_switch_at: string | null
  status: string
}

export interface SwitchResult {
  status: string
  previous_profile: string | null
  new_profile: string
  stopped_containers: string[]
  started_containers: string[]
  skipped_services: string[]
  elapsed_seconds: number
  error: string | null
}

export interface HistoryEntry {
  from_profile: string | null
  to_profile: string
  at: string
  status: string
  elapsed_seconds: number
}

export interface GPUHistoryPoint {
  ts: number
  vram_pct: number
  util_pct: number
}

export interface GPUHistoryResponse {
  history: Record<string, GPUHistoryPoint[]>
}

export interface ClaspStatus {
  running: boolean
  healthy: boolean
  container: string
  clasp_port: number
}

export interface ClaspResult {
  status: string
  container: string
  clasp_port: number
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`)
  if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`)
  return res.json()
}

async function post<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`, { method: 'POST' })
  if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`)
  return res.json()
}

export const api = {
  getGpus: () => get<{ gpus: GPUStatus[] }>('/gpus'),
  getGpuHistory: () => get<GPUHistoryResponse>('/gpu-history'),
  getProfiles: () => get<{ profiles: ProfileInfo[] }>('/profiles'),
  getProfile: (name: string) => get<ProfileDetail>(`/profiles/${name}`),
  getCurrent: () => get<CurrentProfile>('/current'),
  switchProfile: (name: string) => post<SwitchResult>(`/switch/${name}`),
  stopAll: () => post<{ status: string; stopped_containers: string[]; elapsed_seconds: number }>('/stop'),
  getHistory: () => get<{ history: HistoryEntry[] }>('/history'),
  getClaspStatus: (claspPort: number = 8080) => get<ClaspStatus>(`/clasp/status?clasp_port=${claspPort}`),
  startClasp: (vllmPort: number = 8000, claspPort: number = 8080) =>
    fetch(`${BASE}/clasp/start`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ vllm_port: vllmPort, clasp_port: claspPort }),
    }).then(r => { if (!r.ok) throw new Error(`${r.status}`); return r.json() }) as Promise<ClaspResult>,
  stopClasp: (claspPort: number = 8080) =>
    fetch(`${BASE}/clasp/stop?clasp_port=${claspPort}`, { method: 'POST' })
      .then(r => { if (!r.ok) throw new Error(`${r.status}`); return r.json() }) as Promise<ClaspResult>,
}
