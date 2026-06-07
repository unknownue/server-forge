<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type GPUStatus } from '../api'
import GpuHistoryBar from './GpuHistoryBar.vue'

const gpus = ref<GPUStatus[]>([])
let timer: number

async function refresh() {
  try {
    const res = await api.getGpus()
    gpus.value = res.gpus
  } catch {}
}

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 30000)
})

onUnmounted(() => clearInterval(timer))

function vramPct(g: GPUStatus) {
  return Math.round((g.vram_used_mb / g.vram_total_mb) * 100)
}

function fmtMb(mb: number) {
  if (mb >= 1024) return (mb / 1024).toFixed(1) + ' GB'
  return mb + ' MB'
}
</script>

<template>
  <div class="section-title">GPU Status</div>
  <div class="gpu-list">
    <div
      v-for="g in gpus"
      :key="g.id"
      class="gpu-row"
      :class="g.status"
    >
      <div class="gpu-row-header">
        <div class="gpu-id-badge" :class="g.status">GPU {{ g.id }}</div>
        <div class="gpu-row-info">
          <div class="gpu-name">{{ g.name }}</div>
          <div class="gpu-status-tag" :class="g.status">
            {{ g.status === 'in-use' ? '● In Use' : '○ Free' }}
          </div>
        </div>
        <div class="gpu-metrics">
          <div class="metric">
            <span class="value">{{ fmtMb(g.vram_used_mb) }} / {{ fmtMb(g.vram_total_mb) }}</span>
            <span class="label">VRAM ({{ vramPct(g) }}%)</span>
          </div>
          <div class="metric">
            <span class="value">{{ g.utilization_pct }}%</span>
            <span class="label">Util</span>
          </div>
          <div class="metric">
            <span class="value">{{ g.temperature_c }}°C</span>
            <span class="label">Temp</span>
          </div>
        </div>
        <div v-if="g.container" class="gpu-container-info">
          <div class="container-name">{{ g.container.name }}</div>
          <div class="container-detail" v-if="g.container.model">{{ g.container.model }}</div>
          <div class="container-detail" v-if="g.container.port">:{{ g.container.port }}</div>
        </div>
        <div v-if="g.assigned_profile" class="gpu-profile-badge">{{ g.assigned_profile }}</div>
      </div>

      <GpuHistoryBar :gpu-id="g.id" />
    </div>
  </div>
</template>
