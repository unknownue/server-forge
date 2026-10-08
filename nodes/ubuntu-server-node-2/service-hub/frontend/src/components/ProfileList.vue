<script setup lang="ts">
import { reactive } from 'vue'
import type { GPUStatus, ProfileDetail, ProfileInfo, ServiceInfo } from '../api'

const props = defineProps<{
  profiles: ProfileInfo[]
  details: Record<string, ProfileDetail>
  gpus: GPUStatus[]
  current: string | null
  busy: string | null
}>()

// `switch` starts a profile (stopping only its declared conflicts) on the
// chosen GPU; `stop` takes one profile down while coexisting profiles keep
// running.
const emit = defineEmits<{
  (e: 'switch', name: string, gpu?: string): void
  (e: 'stop', name: string): void
}>()

// Per-profile GPU choice for the start selector: 'auto' (freest card at start
// time) or a GPU id as a string. Unset means auto.
const picks = reactive<Record<string, string>>({})
const pickOf = (name: string) => picks[name] ?? 'auto'
const onPick = (name: string, e: Event) => {
  picks[name] = (e.target as HTMLSelectElement).value
}

// A profile is GPU-selectable when it has at least one single-card service
// (`gpu: auto` or one pinned id) — those accept the API's `gpu=` override.
// Multi-card services (TP=2) and script-pinned ones are not selectable.
const isSelectable = (name: string) =>
  !!props.details[name]?.services.some(
    (s) => s.gpu === 'auto' || (!!s.gpu && !s.gpu.includes(',')),
  )

const freeGb = (g: GPUStatus) => `${(g.vram_free_mb / 1024).toFixed(1)} GB free`

// A started service must say where it listens — the port pill is that text.
// While the service is up it is also a link to it (same host, service port).
const svcUrl = (port: number) => `http://${window.location.hostname}:${port}/`

// A profile is "running" when any of its services has a live container —
// the truthful signal now that single-card profiles coexist (the `current`
// prop only records the last switch).
const isRunning = (name: string, details: Record<string, ProfileDetail>) =>
  !!details[name]?.services.some((s) => s.running)

// gpu_allocation.gpu may be a fixed list ([0, 1]), a pinned string ("0"), or
// "auto" (placement decides at start time — the live card is then shown per
// service from assigned_gpus instead).
const gpuLabel = (p: ProfileDetail) => {
  const ids = new Set<number>()
  let auto = false
  for (const a of p.gpu_allocation) {
    const g = a.gpu
    if (g === 'auto') { auto = true; continue }
    if (g == null) continue
    if (Array.isArray(g)) g.forEach((x: any) => ids.add(Number(x)))
    else String(g).split(',').forEach((x) => x.trim() !== '' && ids.add(Number(x)))
  }
  if (ids.size) return [...ids].sort().join(',')
  return auto ? 'auto' : '—'
}

// A service is "up" only when its health endpoint answers; running-but-unhealthy
// is a distinct state worth showing, since that is what a model still loading
// looks like.
const svcState = (s: ServiceInfo) => (s.healthy ? 'on' : s.running ? 'bad' : 'off')
const svcText = (s: ServiceInfo) => (s.healthy ? 'healthy' : s.running ? 'starting / unhealthy' : 'stopped')
</script>

<template>
  <div>
    <div
      v-for="p in profiles"
      :key="p.name"
      class="profile"
      :class="{ active: isRunning(p.name, details) }"
    >
      <div class="phead">
        <div>
          <span class="pname">{{ p.name }}</span>
          <span v-if="isRunning(p.name, details)" class="pill in-use" style="margin-left:8px">running</span>
          <span v-else-if="p.name === current" class="pill" style="margin-left:8px">last switch</span>
        </div>
        <div class="pactions">
          <select
            v-if="isSelectable(p.name)"
            class="gpick"
            :value="pickOf(p.name)"
            :disabled="!!busy"
            title="Choose which GPU to start this profile on"
            @change="onPick(p.name, $event)"
          >
            <option value="auto">GPU: auto (freest)</option>
            <option v-for="g in gpus" :key="g.id" :value="String(g.id)">
              GPU {{ g.id }} · {{ freeGb(g) }}{{ g.containers.length ? ' · in use' : '' }}
            </option>
          </select>
          <button
            class="primary"
            :disabled="!!busy"
            @click="emit('switch', p.name, pickOf(p.name))"
          >
            <span v-if="busy === p.name" class="spin">◌</span>
            {{ busy === p.name ? 'starting…' : (isRunning(p.name, details) ? 'Restart' : 'Start') }}
          </button>
          <button
            v-if="isRunning(p.name, details)"
            class="danger"
            :disabled="!!busy"
            @click="emit('stop', p.name)"
          >
            <span v-if="busy === `stop:${p.name}`" class="spin">◌</span>
            {{ busy === `stop:${p.name}` ? 'stopping…' : 'Stop' }}
          </button>
        </div>
      </div>

      <div class="pdesc">{{ p.description }}</div>

      <div class="prow">
        <span class="pill">{{ p.gpu_count }} GPU</span>
        <span class="pill">v{{ p.version }}</span>
        <span v-for="r in p.roles" :key="r" class="pill">{{ r }}</span>
        <span v-if="details[p.name]" class="pill">GPUs {{ gpuLabel(details[p.name]) }}</span>
        <span v-if="details[p.name]?.conflicts?.length" class="muted">
          conflicts: {{ details[p.name].conflicts.join(', ') }}
        </span>
      </div>

      <div v-if="details[p.name]" class="svc">
        <template v-for="s in details[p.name].services" :key="s.name">
          <span class="dot" :class="svcState(s)" />
          <span>{{ s.name }} — {{ svcText(s) }}</span>
          <!-- Clear port text for every state; a live service links to it. -->
          <a
            v-if="s.port && s.running"
            class="pill port"
            :href="svcUrl(s.port)"
            target="_blank"
            rel="noopener"
            title="Open the service in a new tab"
          >port {{ s.port }}</a>
          <span v-else-if="s.port" class="pill port">port {{ s.port }}</span>
          <span v-if="s.running && s.assigned_gpus.length" class="muted">
            (GPU {{ s.assigned_gpus.join(',') }})
          </span>
          <span v-else-if="s.args.length" class="muted">({{ s.args.join(' ') }})</span>
        </template>
      </div>
    </div>
  </div>
</template>