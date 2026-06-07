<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { api, type GPUHistoryPoint } from '../api'

const props = defineProps<{ gpuId: number }>()
const points = ref<GPUHistoryPoint[]>([])
let timer: number

async function fetchHistory() {
  try {
    const res = await api.getGpuHistory()
    const key = String(props.gpuId)
    points.value = res.history[key] || []
  } catch {}
}

onMounted(() => {
  fetchHistory()
  timer = window.setInterval(fetchHistory, 30000)
})
onUnmounted(() => clearInterval(timer))

function barColor(pct: number): string {
  if (pct > 80) return 'bar-high'
  if (pct > 50) return 'bar-mid'
  return 'bar-low'
}

function fmtTime(ts: number): string {
  return new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}
</script>

<template>
  <div class="gpu-history" v-if="points.length > 0">
    <!-- VRAM Chart -->
    <div class="chart-section">
      <div class="chart-header">
        <span class="chart-title">VRAM Usage (1h)</span>
        <span class="chart-current">
          Current: {{ points[points.length - 1].vram_pct }}%
        </span>
      </div>
      <div class="chart-container">
        <div class="chart-y-axis">
          <span>100%</span>
          <span>75%</span>
          <span>50%</span>
          <span>25%</span>
          <span>0%</span>
        </div>
        <div class="chart-bars">
          <div
            v-for="(p, i) in points"
            :key="i"
            class="bar"
            :class="barColor(p.vram_pct)"
            :style="{ height: Math.max(2, p.vram_pct) + '%' }"
            :title="`${fmtTime(p.ts)}: ${p.vram_pct}%`"
          ></div>
        </div>
      </div>
      <div class="chart-x-axis">
        <span>{{ fmtTime(points[0].ts) }}</span>
        <span v-if="points.length > 2">{{ fmtTime(points[Math.floor(points.length / 2)].ts) }}</span>
        <span>{{ fmtTime(points[points.length - 1].ts) }}</span>
      </div>
    </div>

    <!-- Utilization Chart -->
    <div class="chart-section">
      <div class="chart-header">
        <span class="chart-title">GPU Utilization (1h)</span>
        <span class="chart-current">
          Current: {{ points[points.length - 1].util_pct }}%
        </span>
      </div>
      <div class="chart-container">
        <div class="chart-y-axis">
          <span>100%</span>
          <span>75%</span>
          <span>50%</span>
          <span>25%</span>
          <span>0%</span>
        </div>
        <div class="chart-bars">
          <div
            v-for="(p, i) in points"
            :key="i"
            class="bar"
            :class="barColor(p.util_pct)"
            :style="{ height: Math.max(2, p.util_pct) + '%' }"
            :title="`${fmtTime(p.ts)}: ${p.util_pct}%`"
          ></div>
        </div>
      </div>
      <div class="chart-x-axis">
        <span>{{ fmtTime(points[0].ts) }}</span>
        <span v-if="points.length > 2">{{ fmtTime(points[Math.floor(points.length / 2)].ts) }}</span>
        <span>{{ fmtTime(points[points.length - 1].ts) }}</span>
      </div>
    </div>

    <div class="chart-legend">
      <span class="legend-item"><span class="legend-dot bar-low"></span> Low (&lt;50%)</span>
      <span class="legend-item"><span class="legend-dot bar-mid"></span> Medium (50-80%)</span>
      <span class="legend-item"><span class="legend-dot bar-high"></span> High (&gt;80%)</span>
    </div>
  </div>
  <div v-else class="gpu-history-empty">
    Collecting data... ({{ points.length }}/120 samples)
  </div>
</template>
