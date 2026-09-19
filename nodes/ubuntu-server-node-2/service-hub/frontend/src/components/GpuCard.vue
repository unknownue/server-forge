<script setup lang="ts">
import type { GPUStatus } from '../api'

defineProps<{ gpu: GPUStatus }>()

const gb = (mb: number) => (mb / 1024).toFixed(1)
const vramPct = (g: GPUStatus) =>
  g.vram_total_mb ? Math.round((g.vram_used_mb / g.vram_total_mb) * 100) : 0
// Temperature thresholds are generous: these cards idle near 45 C and run hot
// under sustained inference.
const tempClass = (t: number) => (t >= 90 ? 'bad' : t >= 75 ? 'warn' : '')
</script>

<template>
  <div class="card">
    <div class="gpu-head">
      <div>
        <div class="gpu-name">GPU {{ gpu.id }} · {{ gpu.name }}</div>
        <div class="gpu-slot">{{ gpu.pci_slot }}</div>
      </div>
      <span class="pill" :class="gpu.status">{{ gpu.status }}</span>
    </div>

    <div class="metric">
      <div class="row">
        <span>VRAM</span>
        <span>{{ gb(gpu.vram_used_mb) }} / {{ gb(gpu.vram_total_mb) }} GiB ({{ vramPct(gpu) }}%)</span>
      </div>
      <div class="bar vram"><span :style="{ width: vramPct(gpu) + '%' }" /></div>
    </div>

    <div class="metric">
      <div class="row">
        <span>Utilization</span>
        <span>{{ gpu.utilization_pct }}%</span>
      </div>
      <div class="bar util"><span :style="{ width: Math.min(gpu.utilization_pct, 100) + '%' }" /></div>
    </div>

    <div class="kv">
      <span>Free <b>{{ gb(gpu.vram_free_mb) }} GiB</b></span>
      <span>Temp <b :class="tempClass(gpu.temperature_c)">{{ gpu.temperature_c }} °C</b></span>
      <span v-if="gpu.assigned_profile">Profile <b>{{ gpu.assigned_profile }}</b></span>
    </div>

    <div v-if="gpu.containers.length" class="containers">
      <div v-for="c in gpu.containers" :key="c.name" class="c">
        <code>{{ c.name }}</code>
        <span v-if="c.port">:{{ c.port }}</span>
      </div>
    </div>
    <div v-else class="containers">
      <div class="c"><span>no managed container</span></div>
    </div>
  </div>
</template>