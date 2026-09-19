<script setup lang="ts">
import type { ProfileDetail, ProfileInfo, ServiceInfo } from '../api'

defineProps<{
  profiles: ProfileInfo[]
  details: Record<string, ProfileDetail>
  current: string | null
  busy: string | null
}>()

const emit = defineEmits<{ (e: 'switch', name: string): void }>()

const gpuLabel = (p: ProfileDetail) => {
  const ids = new Set<number>()
  for (const a of p.gpu_allocation) for (const g of a.gpu ?? []) ids.add(g)
  return [...ids].sort().join(',') || '—'
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
      :class="{ active: p.name === current }"
    >
      <div class="phead">
        <div>
          <span class="pname">{{ p.name }}</span>
          <span v-if="p.name === current" class="pill in-use" style="margin-left:8px">active</span>
        </div>
        <button
          class="primary"
          :disabled="!!busy"
          @click="emit('switch', p.name)"
        >
          <span v-if="busy === p.name" class="spin">◌</span>
          {{ busy === p.name ? 'switching…' : (p.name === current ? 'Restart' : 'Start') }}
        </button>
      </div>

      <div class="pdesc">{{ p.description }}</div>

      <div class="prow">
        <span class="pill">{{ p.gpu_count }} GPU</span>
        <span class="pill">v{{ p.version }}</span>
        <span v-for="r in p.roles" :key="r" class="pill">{{ r }}</span>
        <span v-if="details[p.name]" class="pill">GPUs {{ gpuLabel(details[p.name]) }}</span>
      </div>

      <div v-if="details[p.name]" class="svc">
        <template v-for="s in details[p.name].services" :key="s.name">
          <span class="dot" :class="svcState(s)" />
          <span>{{ s.name }} — {{ svcText(s) }}</span>
          <span v-if="s.args.length" class="muted">({{ s.args.join(' ') }})</span>
        </template>
      </div>
    </div>
  </div>
</template>